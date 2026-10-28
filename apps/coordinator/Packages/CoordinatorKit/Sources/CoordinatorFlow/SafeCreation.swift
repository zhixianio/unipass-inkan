import Foundation
import UniPassCore

/// 创建 Safe：和 `contracts/script/DeployTestSafe.s.sol`（已在 Sepolia 上跑通）同样的一笔交易，由提交账户发给
/// MultiSendCallOnly 1.4.1，里面依次是：
/// 1. 每个还没部署的签名器 proxy 调一次 `SafeWebAuthnSignerFactory.createSigner(x, y, verifiers)`；
/// 2. `SafeProxyFactory.createProxyWithNonce(SafeL2 1.4.1, setup(...), saltNonce)`。
///
/// 合约都是 Safe 和 safe-modules 的规范部署，在 Ethereum、Base、Sepolia 上地址相同；部署前还要在链上确认它们都在。
public enum SafeCreation {
    public static let proxyFactory = Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!
    public static let safeL2Singleton = Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!
    /// CompatibilityFallbackHandler 1.4.1。
    public static let fallbackHandler = Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!
    public static let multiSendCallOnly = Address(hex: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2")!
    /// safe-modules 的 SafeWebAuthnSignerFactory。
    public static let signerFactory = Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!

    /// 可以在这些网络上创建：Ethereum、Base、Sepolia。
    public static let chains: [UInt64] = [1, 8453, 11_155_111]

    /// 部署前在链上确认有代码的合约。
    public static let requiredContracts = [proxyFactory, safeL2Singleton, fallbackHandler, multiSendCallOnly, signerFactory]

    /// 要一起部署的签名器 proxy（只有公钥，地址由工厂按公钥算出，部署前用 `getSigner` 核对）。
    public struct NewSigner: Hashable, Sendable {
        public let x: Data
        public let y: Data
        public let verifiers: Data
        public let proxy: Address

        public init(x: Data, y: Data, verifiers: Data, proxy: Address) {
            precondition(x.count == 32 && y.count == 32 && verifiers.count == 22)
            self.x = x
            self.y = y
            self.verifiers = verifiers
            self.proxy = proxy
        }
    }

    /// 新 Safe 的创建参数（SafeL2 1.4.1、CompatibilityFallbackHandler、没有额外初始化），地址用 CREATE2 算出。
    public static func registration(chainID: UInt64, owners: [Address], threshold: UInt64, saltNonce: UInt256, name: String?) -> SafeRegistration {
        var r = SafeRegistration(chainID: chainID, safe: .zero, proxyFactory: proxyFactory, singleton: safeL2Singleton,
                                 saltNonce: saltNonce, owners: owners, threshold: threshold,
                                 fallbackHandler: fallbackHandler, name: name)
        r.safe = SafeAddress.compute(r)!
        return r
    }

    /// 默认阈值：多数（2 个签名人要 2 个，3 个要 2 个，4 个要 3 个）。
    public static func defaultThreshold(owners: Int) -> Int {
        owners / 2 + 1
    }

    public static func randomSaltNonce() -> UInt256 {
        var g = SystemRandomNumberGenerator()
        return UInt256(words: (0..<4).map { _ in g.next() })
    }

    static let createSignerSelector = selector("createSigner(uint256,uint256,uint176)")
    static let createProxySelector = selector("createProxyWithNonce(address,bytes,uint256)")
    static let multiSendSelector = selector("multiSend(bytes)")

    static func selector(_ signature: String) -> Data {
        Data(Keccak.hash256(Data(signature.utf8)).prefix(4))
    }

    public static func createSignerCalldata(_ s: NewSigner) -> Data {
        createSignerSelector + s.x + s.y + Data(count: 10) + s.verifiers
    }

    public static func createProxyCalldata(_ r: SafeRegistration) -> Data {
        let initializer = SafeAddress.setupCalldata(r)
        return createProxySelector + r.singleton.abiEncoded + UInt256(96).bigEndianBytes + r.saltNonce.bigEndianBytes
            + abiBytes(initializer)
    }

    /// 发给 MultiSendCallOnly 的 `multiSend(bytes)` 调用数据。
    public static func deploymentCalldata(deploying signers: [NewSigner], safe r: SafeRegistration) -> Data {
        var packed = Data()
        for s in signers { packed += multiSendEntry(to: signerFactory, data: createSignerCalldata(s)) }
        packed += multiSendEntry(to: r.proxyFactory, data: createProxyCalldata(r))
        return multiSendSelector + UInt256(32).bigEndianBytes + abiBytes(packed)
    }

    /// MultiSend 的一项：operation(1) ‖ to(20) ‖ value(32) ‖ dataLength(32) ‖ data，operation 和 value 都是 0。
    static func multiSendEntry(to: Address, data: Data) -> Data {
        Data([0]) + to.bytes + UInt256.zero.bigEndianBytes + UInt256(UInt64(data.count)).bigEndianBytes + data
    }

    /// 动态 bytes：长度 ‖ 内容 ‖ 补齐到 32 字节。
    static func abiBytes(_ d: Data) -> Data {
        UInt256(UInt64(d.count)).bigEndianBytes + d + Data(count: (32 - d.count % 32) % 32)
    }
}

/// 添加已有 Safe：从交易服务取创建参数，自己用 CREATE2 重算地址，再和链上当前状态比。
/// 签名器离线，只能相信创建参数；所以只接受创建之后 owner、阈值、module、guard、fallback handler 都没改过的 Safe。
public enum ExistingSafe {
    public enum Problem: Error, Hashable, Sendable {
        /// 交易服务给不出创建参数（比如不是通过 SafeProxyFactory 创建的）。
        case noCreationInfo
        /// factory 或 singleton 不是 Safe 官方部署，或者版本不支持。
        case unsupportedFactoryOrVersion
        /// setup 调用数据解不开，或者不是规范编码。
        case setupNotDecodable
        /// 用创建参数重算出的地址和填的地址不一样。
        case addressMismatch
        /// 创建时还执行了额外的初始化调用（setup 的 to / data）。
        case extraSetupCall
        case ownersChanged
        case thresholdChanged
        case hasModules
        case hasGuard
        case fallbackHandlerChanged
        case singletonChanged
        /// 这台 Mac 配对过的签名器一台都不在 owner 里。
        case signerNotOwner
        /// 区块链节点和 Safe 交易服务报的当前状态不一致。
        case sourcesDisagree
    }

    /// `Safe.setup(...)` 调用数据 → 创建参数；必须能用 `SafeAddress.setupCalldata` 原样编码回去（解码在 core，和签名前的核对共用）。
    public static func registration(chainID: UInt64, safe: Address, factory: Address, singleton: Address,
                                    setupData: Data, saltNonce: UInt256, name: String?) throws -> SafeRegistration {
        guard let r = SafeAddress.registration(chainID: chainID, safe: safe, factory: factory, singleton: singleton,
                                               saltNonce: saltNonce, setupCalldata: setupData, name: name)
        else { throw Problem.setupNotDecodable }
        return r
    }

    /// 链上当前的状态（RPC 读，不用交易服务的）。
    public struct OnChain: Hashable, Sendable {
        public var owners: [Address]
        public var threshold: UInt64
        public var modules: [Address]
        public var guardAddress: Address
        public var fallbackHandler: Address
        public var singleton: Address

        public init(owners: [Address], threshold: UInt64, modules: [Address], guardAddress: Address, fallbackHandler: Address, singleton: Address) {
            self.owners = owners
            self.threshold = threshold
            self.modules = modules
            self.guardAddress = guardAddress
            self.fallbackHandler = fallbackHandler
            self.singleton = singleton
        }
    }

    /// 当前状态里的各项。
    public enum Field: Hashable, Sendable, CaseIterable {
        case owners, threshold, modules, guardAddress, fallbackHandler, singleton
    }

    /// 两个来源（节点、交易服务）报的状态哪几项不一样。owner 和 module 不看顺序。
    public static func disagreements(_ a: OnChain, _ b: OnChain) -> Set<Field> {
        var out: Set<Field> = []
        if Set(a.owners) != Set(b.owners) || a.owners.count != b.owners.count { out.insert(.owners) }
        if a.threshold != b.threshold { out.insert(.threshold) }
        if Set(a.modules) != Set(b.modules) || a.modules.count != b.modules.count { out.insert(.modules) }
        if a.guardAddress != b.guardAddress { out.insert(.guardAddress) }
        if a.fallbackHandler != b.fallbackHandler { out.insert(.fallbackHandler) }
        if a.singleton != b.singleton { out.insert(.singleton) }
        return out
    }

    /// 加进来以后每次刷新复查：module、guard、fallback handler、singleton 和创建时比，变了的那几项。
    /// 这几项能绕过签名人动钱，或者改掉签名的含义，签名器离线核对不了。换签名人、改门限是正常操作，不在这里报。
    public static func configurationChanges(_ r: SafeRegistration, now: OnChain) -> Set<Field> {
        var out: Set<Field> = []
        if !now.modules.isEmpty { out.insert(.modules) }
        if now.guardAddress != .zero { out.insert(.guardAddress) }
        if now.fallbackHandler != r.fallbackHandler { out.insert(.fallbackHandler) }
        if now.singleton != r.singleton { out.insert(.singleton) }
        return out
    }

    /// 存储槽：`keccak256("guard_manager.guard.address")`、`keccak256("fallback_manager.handler.address")`、singleton 在第 0 槽。
    public static let guardSlot = Keccak.hash256(Data("guard_manager.guard.address".utf8))
    public static let fallbackHandlerSlot = Keccak.hash256(Data("fallback_manager.handler.address".utf8))
    public static let singletonSlot = Data(count: 32)

    /// 能不能添加。返回第一个不满足的条件；全部满足返回 nil。
    /// `onChain` 是区块链节点读的，`service` 是 Safe 交易服务 `/safes/{address}/` 报的；两边必须一致（不只信一个来源）。
    public static func problem(_ r: SafeRegistration, onChain: OnChain, service: OnChain, signers: Set<Address>) -> Problem? {
        guard SafeAddress.initCode(factory: r.proxyFactory, singleton: r.singleton) != nil else { return .unsupportedFactoryOrVersion }
        guard SafeAddress.compute(r) == r.safe else { return .addressMismatch }
        guard r.to == .zero, r.data.isEmpty else { return .extraSetupCall }
        guard disagreements(onChain, service).isEmpty else { return .sourcesDisagree }
        guard onChain.singleton == r.singleton else { return .singletonChanged }
        guard Set(onChain.owners) == Set(r.owners), onChain.owners.count == r.owners.count else { return .ownersChanged }
        guard onChain.threshold == r.threshold else { return .thresholdChanged }
        guard onChain.modules.isEmpty else { return .hasModules }
        guard onChain.guardAddress == .zero else { return .hasGuard }
        guard onChain.fallbackHandler == r.fallbackHandler else { return .fallbackHandlerChanged }
        guard r.owners.contains(where: signers.contains) else { return .signerNotOwner }
        return nil
    }

    /// 核对都通过以后、加进列表之前给用户看的：签名人、门限，以及没配对的签名人能不能自己凑够门限。
    ///
    /// 能凑够时（例如 2-of-3 的 Inkan + Ledger + Trezor），这些交易不经过签名器，签名器的离线核对对它们不起作用。
    /// 这是正当的配置，所以不拒绝，但要用户明确确认才能添加；需要配对的签名器才够门限的不出现这个确认。
    public struct Review: Hashable, Sendable {
        public let registration: SafeRegistration
        /// 没和这台 Mac 配对的签名人个数。
        public let unpairedSigners: Int

        public init(_ r: SafeRegistration, paired: Set<Address>) {
            registration = r
            unpairedSigners = Set(r.owners).subtracting(paired).count
        }

        /// 没配对的签名人自己就够门限。
        public var needsAcknowledgement: Bool { UInt64(unpairedSigners) >= registration.threshold }

        public func canAdd(acknowledged: Bool) -> Bool { !needsAcknowledgement || acknowledged }
    }
}

