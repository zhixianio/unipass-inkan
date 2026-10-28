import Foundation
import UniPassCore

/// 提交账户能签什么（白名单）。只有这三种，其他一律拒绝：
/// 1. 普通转账（data 为空，gas 正好 21000）：转出余额；
/// 2. 对已登记 Safe 的 `execTransaction`（value 为 0；按 (链, 地址) 匹配，同一个地址在别的链上不算）；
/// 3. 对 Safe 1.4.1 规范部署的 MultiSendCallOnly 的 `multiSend`（value 为 0）：创建 Safe 用。批量里的每一项都要解码，
///    只允许 value 为 0 的 CALL，调用 `SafeWebAuthnSignerFactory.createSigner` 或 SafeProxyFactory 1.4.1 的
///    `createProxyWithNonce`（singleton 必须是官方部署），其他一律拒绝。
///
/// 三种都只签支持的链（Ethereum、Base、Sepolia），gas 和每 gas 价格都有硬上限：节点（包括默认的公共节点）
/// 报的 gas、小费、baseFee 都不可信，这里是签名前的最后一道。
///
/// 另外在私钥这一层只签 EIP-1559（type 2）交易：type-4 交易和 EIP-7702 授权（`0x05 ‖ rlp(…)`）
/// 根本到不了签名。7702 钓鱼就是骗 EOA 签委托授权；桌面端整个被攻破时这条拦不住，
/// 但能保证我们自己的代码不会被诱导去签。
public struct SigningPolicy: Hashable, Sendable {
    /// 已登记的 Safe：同一个地址在不同链上是不同的 Safe。
    public struct RegisteredSafe: Hashable, Sendable {
        public let chainID: UInt64
        public let address: Address

        public init(chainID: UInt64, address: Address) {
            self.chainID = chainID
            self.address = address
        }
    }

    public var safes: Set<RegisteredSafe>

    public init(safes: Set<RegisteredSafe>) {
        self.safes = safes
    }

    /// 只在这些链上签：Ethereum、Base、Sepolia。
    public static let chains: Set<UInt64> = [1, 8453, 11_155_111]

    // MARK: 上限

    /// 小费上限 2 gwei：报价时节点报得更高也只给这么多（最多慢一点进块）。
    public static let maxTip = UInt256(2_000_000_000)
    /// 每 gas 最多付 500 gwei（含 baseFee）。
    public static let maxFeePerGas = UInt256(500_000_000_000)
    public static let transferGas: UInt64 = 21_000
    /// `execTransaction` 的 gas 上限。实测 Sepolia 2-of-2（一个 WebAuthn 签名）转 ETH 用了 200,039。
    public static let executionGasLimit: UInt64 = 1_500_000

    /// 部署批量的 gas 上限，按要一起部署的签名器个数算。实测一台签名器 + Safe 用了 1,947,617（`createSigner` 约 590k）。
    public static func deploymentGasLimit(signers: Int) -> UInt64 {
        2_500_000 + 1_000_000 * UInt64(signers)
    }

    /// Safe 1.4.1 的 MultiSendCallOnly（三条链地址相同，见 core 的 CallDecoder）。
    public static let multiSendCallOnly141 = Address(hex: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2")!

    /// safe-modules 的 SafeWebAuthnSignerFactory、Safe 1.4.1 的 SafeProxyFactory（三条链地址相同）。
    public static let signerFactory = Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!
    public static let proxyFactory141 = Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!

    static let execTransaction = selector("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)")
    static let multiSend = selector("multiSend(bytes)")
    static let createSigner = selector("createSigner(uint256,uint256,uint176)")
    static let createProxyWithNonce = selector("createProxyWithNonce(address,bytes,uint256)")

    static func selector(_ signature: String) -> Data {
        Data(Keccak.hash256(Data(signature.utf8)).prefix(4))
    }

    public enum Violation: Error, Equatable, Sendable {
        case notAllowed
        /// 不是支持的链。
        case wrongChain
        case gasLimitTooHigh
        /// 小费或每 gas 价格超过上限。
        case feeTooHigh
    }

    public func check(_ tx: EIP1559Transaction) throws {
        guard Self.chains.contains(tx.chainID) else { throw Violation.wrongChain }
        guard !(Self.maxTip < tx.maxPriorityFeePerGas), !(Self.maxFeePerGas < tx.maxFeePerGas),
              !(tx.maxFeePerGas < tx.maxPriorityFeePerGas) else { throw Violation.feeTooHigh }
        guard let limit = gasLimit(tx) else { throw Violation.notAllowed }
        guard tx.gasLimit <= limit else { throw Violation.gasLimitTooHigh }
    }

    /// 白名单里的交易允许的 gas 上限；不在白名单里返回 nil。
    func gasLimit(_ tx: EIP1559Transaction) -> UInt64? {
        if tx.data.isEmpty { return Self.transferGas }
        let selector = tx.data.prefix(4)
        if tx.value.isZero, safes.contains(RegisteredSafe(chainID: tx.chainID, address: tx.to)), selector == Self.execTransaction {
            return Self.executionGasLimit
        }
        if tx.value.isZero, tx.to == Self.multiSendCallOnly141, selector == Self.multiSend, let signers = Self.deploymentSigners(tx.data) {
            return Self.deploymentGasLimit(signers: signers)
        }
        return nil
    }

    /// `multiSend(bytes)` 的批量里只有创建签名器 proxy 和创建 Safe 时，返回创建签名器的个数；否则 nil。
    /// ABI 编码必须规范（偏移 32、长度和补零都对得上）。
    static func deploymentSigners(_ calldata: Data) -> Int? {
        let b = [UInt8](calldata)
        guard b.count >= 4 + 64, let offset = uint(b, 4), offset == 32, let length = uint(b, 36),
              b.count == 4 + 64 + length + (32 - length % 32) % 32, b[(68 + length)...].allSatisfy({ $0 == 0 }) else { return nil }
        var i = 68
        let end = 68 + length
        var calls = 0
        var signers = 0
        while i < end {
            // operation(1) ‖ to(20) ‖ value(32) ‖ dataLength(32) ‖ data
            guard end - i >= 85, b[i] == 0, let value = UInt256(bigEndian: Data(b[(i + 21)..<(i + 53)])), value.isZero,
                  let n = uint(b, i + 53), end - (i + 85) >= n else { return nil }
            let to = Address(bytes: Data(b[(i + 1)..<(i + 21)]))!
            guard isDeploymentCall(to: to, data: Data(b[(i + 85)..<(i + 85 + n)])) else { return nil }
            if to == signerFactory { signers += 1 }
            i += 85 + n
            calls += 1
        }
        return calls > 0 ? signers : nil
    }

    static func isDeploymentCall(to: Address, data: Data) -> Bool {
        if to == signerFactory, data.prefix(4) == createSigner { return data.count == 4 + 3 * 32 }
        if to == proxyFactory141, data.prefix(4) == createProxyWithNonce, data.count >= 4 + 4 * 32 {
            let word = data.dropFirst(4).prefix(32)
            guard word.prefix(12).allSatisfy({ $0 == 0 }), let singleton = Address(bytes: Data(word.suffix(20))) else { return false }
            return SafeAddress.initCode(factory: proxyFactory141, singleton: singleton) != nil
        }
        return false
    }

    /// 从 `b[at]` 开始的一个 32 字节大端整数（太大的返回 nil）。
    static func uint(_ b: [UInt8], _ at: Int) -> Int? {
        guard b.count >= at + 32, b[at..<(at + 24)].allSatisfy({ $0 == 0 }) else { return nil }
        let n = b[(at + 24)..<(at + 32)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return n < 1 << 24 ? Int(n) : nil
    }
}

/// 交给私钥签名的原始载荷：只接受 EIP-1559（第一个字节 0x02）。
enum SigningPayload {
    enum Rejected: Error, Equatable {
        /// 0x04：EIP-7702 的 type-4 交易；0x05：7702 授权的 magic；其他类型、旧式交易同样拒绝。
        case unsupportedType(UInt8?)
    }

    static func validate(_ payload: Data) throws {
        guard payload.first == 0x02 else { throw Rejected.unsupportedType(payload.first) }
    }
}
