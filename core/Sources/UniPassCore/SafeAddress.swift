import Foundation

/// 离线核对 Safe 地址（`unipass-safe` 登记时用）：
/// `address = keccak256(0xff ‖ factory ‖ keccak256(keccak256(initializer) ‖ saltNonce) ‖ initCodeHash)[12…]`，
/// 其中 `initializer = Safe.setup(...)` 的调用数据，`initCodeHash = keccak256(proxyCreationCode ‖ uint256(singleton))`。
///
/// 只内置 (官方 factory, 官方 singleton) 的 initCodeHash，不内置代理字节码。哈希由
/// `testvectors/generator/build_safe_initcode.mjs` 从三条链上各 factory 的 `proxyCreationCode()` 算出
///（区块 1: 26270722, 8453: 53077174, 11155111: 11991884；四个 factory 在三条链上的字节码一致）。
/// factory 和 singleton 地址来自 safe-deployments（见 `SafeDeployments`、标签库）。
public enum SafeAddress {
    public struct InitCode: Hashable, Sendable {
        public let factory: Address
        public let singleton: Address
        public let version: String
        public let isL2: Bool
        public let initCodeHash: Data

        init(factory: String, singleton: String, version: String, isL2: Bool, initCodeHash: String) {
            self.factory = Address(hex: factory)!
            self.singleton = Address(hex: singleton)!
            self.version = version
            self.isL2 = isL2
            self.initCodeHash = Data(hex: initCodeHash)!
        }
    }

    /// 4 个 factory（1.3.0 canonical / eip155、1.4.1、1.5.0）× 8 个 singleton。三条链上都一样。
    public static let initCodes: [InitCode] = [
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552", version: "1.3.0", isL2: false,
              initCodeHash: "0x56e3081a3d1bb38ed4eed1a39f7729c3cc77c7825794c15bbf326f3047fd779c"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0x3E5c63644E683549055b9Be8653de26E0B4CD36E", version: "1.3.0", isL2: true,
              initCodeHash: "0xcaf2dc2f91b804b2fcf1ed3a965a1ff4404b840b80c124277b00a43b4634b2ce"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0x69f4D1788e39c87893C980c06EdF4b7f686e2938", version: "1.3.0", isL2: false,
              initCodeHash: "0xb3e501cfec8bd01fe46110901ec2dbff08b51dfc5ac094de6535e2c4bbdb59d9"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0xfb1bffC9d739B8D520DaF37dF666da4C687191EA", version: "1.3.0", isL2: true,
              initCodeHash: "0xea577b319e453ad8c9c606cacfe42c5750522aa0379d419931cb34698e3630e0"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a", version: "1.4.1", isL2: false,
              initCodeHash: "0x8a4e78191a4e9b5bb5e3620b48ae41e98f6f845058e79b18c738261b7a6a3db0"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762", version: "1.4.1", isL2: true,
              initCodeHash: "0xa9c18020cdbfd2622bb308d763c9d4217939482217f1becb5536071338d166c3"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0xFf51A5898e281Db6DfC7855790607438dF2ca44b", version: "1.5.0", isL2: false,
              initCodeHash: "0x441b52e43261097993ccabe8c1019f09abd3ccde9bf271df659a20c3bc68f695"),
        .init(factory: "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2", singleton: "0xEdd160fEBBD92E350D4D398fb636302fccd67C7e", version: "1.5.0", isL2: true,
              initCodeHash: "0x1e21eeb3fa45cb0bfd4c5975009e3a9e387f164c4c96c23ae61539d8f1fa513d"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552", version: "1.3.0", isL2: false,
              initCodeHash: "0x56e3081a3d1bb38ed4eed1a39f7729c3cc77c7825794c15bbf326f3047fd779c"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0x3E5c63644E683549055b9Be8653de26E0B4CD36E", version: "1.3.0", isL2: true,
              initCodeHash: "0xcaf2dc2f91b804b2fcf1ed3a965a1ff4404b840b80c124277b00a43b4634b2ce"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0x69f4D1788e39c87893C980c06EdF4b7f686e2938", version: "1.3.0", isL2: false,
              initCodeHash: "0xb3e501cfec8bd01fe46110901ec2dbff08b51dfc5ac094de6535e2c4bbdb59d9"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0xfb1bffC9d739B8D520DaF37dF666da4C687191EA", version: "1.3.0", isL2: true,
              initCodeHash: "0xea577b319e453ad8c9c606cacfe42c5750522aa0379d419931cb34698e3630e0"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a", version: "1.4.1", isL2: false,
              initCodeHash: "0x8a4e78191a4e9b5bb5e3620b48ae41e98f6f845058e79b18c738261b7a6a3db0"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762", version: "1.4.1", isL2: true,
              initCodeHash: "0xa9c18020cdbfd2622bb308d763c9d4217939482217f1becb5536071338d166c3"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0xFf51A5898e281Db6DfC7855790607438dF2ca44b", version: "1.5.0", isL2: false,
              initCodeHash: "0x441b52e43261097993ccabe8c1019f09abd3ccde9bf271df659a20c3bc68f695"),
        .init(factory: "0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC", singleton: "0xEdd160fEBBD92E350D4D398fb636302fccd67C7e", version: "1.5.0", isL2: true,
              initCodeHash: "0x1e21eeb3fa45cb0bfd4c5975009e3a9e387f164c4c96c23ae61539d8f1fa513d"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552", version: "1.3.0", isL2: false,
              initCodeHash: "0x7883491ea8eb82fd854c6f29ff3874b0e83ad895b5d83b8dacb941ae94fe533b"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0x3E5c63644E683549055b9Be8653de26E0B4CD36E", version: "1.3.0", isL2: true,
              initCodeHash: "0x4e39b0edc5953f51721b53b919d7af6a9e9a2c369684ad2129f4f58742a4ee64"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0x69f4D1788e39c87893C980c06EdF4b7f686e2938", version: "1.3.0", isL2: false,
              initCodeHash: "0xc36c70b707859c2593323bb5854079af0b4997049e1dc12844fe999385bcb16b"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0xfb1bffC9d739B8D520DaF37dF666da4C687191EA", version: "1.3.0", isL2: true,
              initCodeHash: "0x36ecfc54151ff61022a1e3bd336c208cf51b2b134e77e1a130bf52e74d1db789"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a", version: "1.4.1", isL2: false,
              initCodeHash: "0x76733d705f71b79841c0ee960a0ca880f779cde7ef446c989e6d23efc0a4adfb"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762", version: "1.4.1", isL2: true,
              initCodeHash: "0xe298282cefe913ab5d282047161268a8222e4bd4ed106300c547894bbefd31ee"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0xFf51A5898e281Db6DfC7855790607438dF2ca44b", version: "1.5.0", isL2: false,
              initCodeHash: "0xc6bb53dd7705468bfb58021c379a7699d0808c0377bedcedabefd580975d4777"),
        .init(factory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67", singleton: "0xEdd160fEBBD92E350D4D398fb636302fccd67C7e", version: "1.5.0", isL2: true,
              initCodeHash: "0x1b94aebb5a7df6dff11d93589204a6bbc99b4b8c9014bf1d386d006c2c17a881"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552", version: "1.3.0", isL2: false,
              initCodeHash: "0x04fda421e33682b4d2f694c0d19c0c2d036b44aaa357ec30a9117389c8f2738e"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0x3E5c63644E683549055b9Be8653de26E0B4CD36E", version: "1.3.0", isL2: true,
              initCodeHash: "0x46fa261bb09a7be604e758227606c7dc98710b49e3e54581894a61088a06deb5"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0x69f4D1788e39c87893C980c06EdF4b7f686e2938", version: "1.3.0", isL2: false,
              initCodeHash: "0x5a8292814e7a510a5ff11503c1580eeb7f02fbddc3e708bf62f7e0a07ffdb328"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0xfb1bffC9d739B8D520DaF37dF666da4C687191EA", version: "1.3.0", isL2: true,
              initCodeHash: "0x21bfd33d3890c31faa61d47db8deeb08a903dbd18ad876882451935ed46638cf"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a", version: "1.4.1", isL2: false,
              initCodeHash: "0x3e0c73cd26c0b0887d5cb1b65512befd9c18b2a9ce5132fa998f67ddf5d6c7ad"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762", version: "1.4.1", isL2: true,
              initCodeHash: "0x7bd14b176c53e3edb0125708c238381eeec6b78f2386bfc419685853e339fc7a"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0xFf51A5898e281Db6DfC7855790607438dF2ca44b", version: "1.5.0", isL2: false,
              initCodeHash: "0x9dd695a8d96e2c0f6ede304e13cc2efe754fa353b7389a23340c9317113bc975"),
        .init(factory: "0x14F2982D601c9458F93bd70B218933A6f8165e7b", singleton: "0xEdd160fEBBD92E350D4D398fb636302fccd67C7e", version: "1.5.0", isL2: true,
              initCodeHash: "0xc00f8ed2d8e1bacf9a81836a956d9be01fbb50416bce76c09d18859e6bb6d223"),
    ]

    /// 各版本官方的 CompatibilityFallbackHandler（safe-deployments `compatibility_fallback_handler.json`；
    /// 1.3.0 有 canonical 和 eip155 两份）。支持的三条链上地址相同，测试逐链对照标签库核对。
    /// 登记时 fallback handler 只能是零地址或 singleton 同版本的这几个：handler 会回答 EIP-1271 签名校验，
    /// 换成别的合约就能让 Safe "认可"任何签名（安全核查 P0-1）。
    public static let compatibilityFallbackHandlers: [String: [Address]] = [
        "1.3.0": [Address(hex: "0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4")!, Address(hex: "0x017062a1dE2FE6b99BE3d9d37841FeD19F573804")!],
        "1.4.1": [Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!],
        "1.5.0": [Address(hex: "0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4")!],
    ]

    public static func initCode(factory: Address, singleton: Address) -> InitCode? {
        initCodes.first { $0.factory == factory && $0.singleton == singleton }
    }

    static let setupSelector = Data(Keccak.hash256(Data("setup(address[],uint256,address,bytes,address,address,uint256,address)".utf8)).prefix(4))

    /// `Safe.setup(owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver)` 的调用数据。
    public static func setupCalldata(_ r: SafeRegistration) -> Data {
        let ownersOffset = 8 * 32
        let dataOffset = ownersOffset + 32 * (1 + r.owners.count)
        var head = Data()
        head += UInt256(UInt64(ownersOffset)).bigEndianBytes
        head += UInt256(r.threshold).bigEndianBytes
        head += r.to.abiEncoded
        head += UInt256(UInt64(dataOffset)).bigEndianBytes
        head += r.fallbackHandler.abiEncoded
        head += r.paymentToken.abiEncoded
        head += r.payment.bigEndianBytes
        head += r.paymentReceiver.abiEncoded
        var tail = UInt256(UInt64(r.owners.count)).bigEndianBytes
        for o in r.owners { tail += o.abiEncoded }
        tail += UInt256(UInt64(r.data.count)).bigEndianBytes + r.data + Data(count: (32 - r.data.count % 32) % 32)
        return setupSelector + head + tail
    }

    /// 按登记里的参数算出的 Safe 地址；factory / singleton 不是官方组合时返回 nil。
    public static func compute(_ r: SafeRegistration) -> Address? {
        guard let ic = initCode(factory: r.proxyFactory, singleton: r.singleton) else { return nil }
        let salt = Keccak.hash256(Keccak.hash256(setupCalldata(r)) + r.saltNonce.bigEndianBytes)
        let h = Keccak.hash256(Data([0xFF]) + r.proxyFactory.bytes + salt + ic.initCodeHash)
        return Address(bytes: Data(h.suffix(20)))
    }

    public enum VerificationError: Error, Hashable, Sendable {
        case unsupportedChain(UInt64)
        /// factory 或 singleton 不是 Safe 官方部署（或组合不在表里）。
        case unknownFactoryOrSingleton
        /// 按参数算出的地址和登记里的地址不同。
        case addressMismatch(computed: Address)
        /// CREATE2 核对通过，但这台 Signer 的 owner 地址不在 setup 的 owner 列表里。
        case signerNotAnOwner(Address)
        /// setup 带了额外调用（`to` 不是零地址或 `data` 不为空）：setup 会 DELEGATECALL 它，能在创建时加 module 或 owner。
        case setupCall(to: Address)
        /// setup 带了付款（`paymentToken` / `payment` / `paymentReceiver` 不为零）。
        case setupPayment
        /// fallback handler 不是零地址，也不是同版本官方的 CompatibilityFallbackHandler。
        case unofficialFallbackHandler(Address)
    }

    /// 可以存进"我的 Safe"的登记：CREATE2 核对通过，**并且**这台 Signer 在创建时的 owner 里。
    /// 只能经 `verify(_:signer:)` 构造；Signer 的本地存储只收这个类型，所以"不是 owner 也登记了"走不通。
    /// 注意 CREATE2 只能证明 Safe **创建时**的 owner 和门限，之后链上改过的话这里不知道。
    public struct VerifiedSafe: Hashable, Sendable {
        public let registration: SafeRegistration
        public let initCode: InitCode
        /// 这台 Signer 在 owner 里的地址。
        public let signer: Address
    }

    /// 核对登记：链在首发范围、factory 和 singleton 是官方部署、CREATE2 算出的地址一致，
    /// 并且 setup 没有额外调用、没有付款、fallback handler 是零地址或同版本官方的 CompatibilityFallbackHandler。
    /// 后三项是因为 CREATE2 只证明创建参数，证明不了 setup 执行后 Safe 的状态（安全核查 P0-1）。
    public static func verify(_ r: SafeRegistration) throws -> InitCode {
        guard SafeDeployments.supportedChains.contains(r.chainID) else { throw VerificationError.unsupportedChain(r.chainID) }
        guard let ic = initCode(factory: r.proxyFactory, singleton: r.singleton), let computed = compute(r) else {
            throw VerificationError.unknownFactoryOrSingleton
        }
        guard computed == r.safe else { throw VerificationError.addressMismatch(computed: computed) }
        guard r.to == .zero, r.data.isEmpty else { throw VerificationError.setupCall(to: r.to) }
        guard r.paymentToken == .zero, r.payment.isZero, r.paymentReceiver == .zero else { throw VerificationError.setupPayment }
        guard r.fallbackHandler == .zero || compatibilityFallbackHandlers[ic.version, default: []].contains(r.fallbackHandler) else {
            throw VerificationError.unofficialFallbackHandler(r.fallbackHandler)
        }
        return ic
    }

    /// 登记前的完整核对：先按 `verify(_:)` 核对 CREATE2，再要求 `signer`（本机 signer proxy）在 owner 列表里。
    public static func verify(_ r: SafeRegistration, signer: Address) throws -> VerifiedSafe {
        let ic = try verify(r)
        guard r.owners.contains(signer) else { throw VerificationError.signerNotAnOwner(signer) }
        return VerifiedSafe(registration: r, initCode: ic, signer: signer)
    }
}
