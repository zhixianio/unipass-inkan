import Foundation
import SafeTransactionService
import UniPassCore

/// 提交账户：一个普通 EOA，**不是 Safe 的 owner**，只放少量 gas，替用户把签齐的交易发上链。
///
/// - 私钥在钥匙串里，第一次用时生成；不提供导出（不做备份）。被盗或丢失只损失里面的少量 gas，可以换一个新的。
/// - 只签白名单里的交易（`SigningPolicy`）：对已登记 Safe 的 `execTransaction`、转出余额、部署用的 MultiSendCallOnly；
///   从不签 EIP-7702 授权或 type-4 交易。
/// - 不用 Safe 的退款机制：SafeTx 的退款字段一律为 0，网络费由这个账户自己付。
public struct SubmitterAccount: Sendable {
    let key: Secp256k1Key
    public let policy: SigningPolicy
    public var address: Address { key.address }

    init(key: Secp256k1Key, policy: SigningPolicy) {
        self.key = key
        self.policy = policy
    }

    /// 同一把私钥，换一份白名单（Safe 列表变了之后用）。
    public func with(policy: SigningPolicy) -> SubmitterAccount {
        SubmitterAccount(key: key, policy: policy)
    }

    /// 钥匙串里已有的账户；没有就生成一个存起来。`policy` 列出允许执行的 Safe。
    public static func loadOrCreate(policy: SigningPolicy) throws -> SubmitterAccount {
        if let raw = try SubmitterKeyStore.load() { return SubmitterAccount(key: try Secp256k1Key(raw), policy: policy) }
        let key = try Secp256k1Key.generate()
        try SubmitterKeyStore.save(key.rawRepresentation)
        return SubmitterAccount(key: key, policy: policy)
    }

    /// 换一个新的提交账户：旧私钥从钥匙串删除（里面剩的钱就取不回了，界面要先提示转出）。
    public static func replace(policy: SigningPolicy) throws -> SubmitterAccount {
        try SubmitterKeyStore.delete()
        return try loadOrCreate(policy: policy)
    }

    // MARK: 组交易

    /// 发交易前的报价：用多少 gas、每 gas 最多付多少、最多花多少。
    public struct Quote: Sendable {
        public let transaction: EIP1559Transaction
        /// value + gasLimit × maxFeePerGas：余额至少要这么多才发得出去。
        public let maxCost: UInt256
        /// 预计实际花的网络费：gasLimit × (baseFee + tip)。
        public let expectedFee: UInt256
    }

    public enum SubmitError: Error, Equatable, Sendable {
        /// 余额不够付 `needed`（含网络费上限）。
        case insufficientBalance(balance: UInt256, needed: UInt256)
        /// 转出余额时，余额连网络费都不够。
        case nothingToSweep
        case overflow
        /// 节点报的 chainId 不是这笔交易该去的链。
        case wrongChain(expected: UInt64, reported: UInt64)
        /// 网络费上限超过本地估算的 `maxCostOverEstimate` 倍（节点报的 gas 不可信）。
        case costAboveEstimate
    }

    /// 网络费上限（gasLimit × maxFee）最多是本地估算（本地 gas × (baseFee + 小费)）的几倍。
    static let maxCostOverEstimate: UInt64 = 4

    /// 本地估算的 gas（不问节点）：转账 21000；`execTransaction` 400k（实测 2-of-2 约 200k，留出多几个 WebAuthn 签名的余量）；
    /// 部署 1.4M + 每台签名器 600k（实测一台约 1.95M）。
    static func localGasEstimate(_ tx: EIP1559Transaction) -> UInt64 {
        if tx.data.isEmpty { return transferGas }
        if let signers = SigningPolicy.deploymentSigners(tx.data, chainID: tx.chainID) { return 1_400_000 + 600_000 * UInt64(signers) }
        return 400_000
    }

    /// 普通转账的 gas。
    static let transferGas: UInt64 = 21_000

    /// 估算 `to` + `data` 的 gas（多留 25%），按当前 baseFee 的两倍 + 小费定每 gas 上限。
    ///
    /// 节点不可信：它报的 chainId 必须等于 `expectedChainID`（这笔交易该去的链）；小费压到 `SigningPolicy.maxTip`；
    /// 网络费上限不能超过本地估算的 `maxCostOverEstimate` 倍；最后过一遍白名单（含 gas 和价格的硬上限），
    /// 报价通过了，发的时候才签得出来。
    public func quote(to: Address, data: Data, value: UInt256 = .zero, gasLimit: UInt64? = nil, chainID expectedChainID: UInt64,
                      rpc: EthRPC) async throws -> Quote {
        let reported = try await rpc.chainID()
        guard reported == expectedChainID else { throw SubmitError.wrongChain(expected: expectedChainID, reported: reported) }
        async let nonce = rpc.transactionCount(address)
        async let baseFee = rpc.baseFee()
        async let tip = rpc.maxPriorityFeePerGas()
        let gas: UInt64
        if let gasLimit {
            gas = gasLimit
        } else {
            let estimate = try await rpc.estimateGas(from: address, to: to, data: data, value: value)
            guard estimate.words[1...].allSatisfy({ $0 == 0 }) else { throw SubmitError.overflow }
            gas = estimate.words[0] + estimate.words[0] / 4
        }
        let fees = try Self.fees(baseFee: try await baseFee, tip: try await tip)
        let tx = EIP1559Transaction(chainID: expectedChainID, nonce: try await nonce, maxPriorityFeePerGas: fees.tip,
                                    maxFeePerGas: fees.max, gasLimit: gas, to: to, value: value, data: data)
        try policy.check(tx)
        // 过了白名单，每 gas 价格都在 500 gwei 以内，下面的乘法不会溢出。
        guard let maxCost = tx.maxCost, let expected = Self.mul(gas, fees.expected), let maxFee = Self.mul(gas, fees.max),
              let allowed = Self.mul(Self.maxCostOverEstimate * Self.localGasEstimate(tx), fees.expected)
        else { throw SubmitError.overflow }
        guard !(allowed < maxFee) else { throw SubmitError.costAboveEstimate }
        return Quote(transaction: tx, maxCost: maxCost, expectedFee: expected)
    }

    /// 小费至少 0.001 gwei（有的公共节点报 0 或几 wei，交易会卡住），至多 `SigningPolicy.maxTip`；
    /// 每 gas 上限 = 2 × baseFee + 小费（超过 `SigningPolicy.maxFeePerGas` 的由白名单拒绝）。
    static func fees(baseFee: UInt256, tip: UInt256) throws -> (tip: UInt256, max: UInt256, expected: UInt256) {
        let minTip = UInt256(1_000_000)
        let t = tip < minTip ? minTip : (SigningPolicy.maxTip < tip ? SigningPolicy.maxTip : tip)
        guard let doubled = baseFee.adding(baseFee), let max = doubled.adding(t), let expected = baseFee.adding(t) else {
            throw SubmitError.overflow
        }
        return (t, max, expected)
    }

    static func mul(_ gas: UInt64, _ price: UInt256) -> UInt256? {
        guard price.words[1...].allSatisfy({ $0 == 0 }) else { return nil }
        let (high, low) = gas.multipliedFullWidth(by: price.words[0])
        return UInt256(words: [low, high, 0, 0])
    }

    /// 签名并广播，返回交易哈希。余额不够付上限时不发。
    public func send(_ quote: Quote, rpc: EthRPC) async throws -> String {
        let balance = try await rpc.balance(of: address)
        guard balance >= quote.maxCost else { throw SubmitError.insufficientBalance(balance: balance, needed: quote.maxCost) }
        return try await rpc.sendRawTransaction(signed(quote.transaction))
    }

    /// 先过白名单，再签。
    func signed(_ tx: EIP1559Transaction) throws -> Data {
        try policy.check(tx)
        return tx.raw(try key.sign(payload: tx.signingPayload))
    }

    /// 转出余额：把全部余额减去网络费上限转到 `recipient`（多付的上限部分会留在账户里，通常不到一分钱）。
    public func sweepQuote(to recipient: Address, chainID: UInt64, rpc: EthRPC) async throws -> Quote {
        let balance = try await rpc.balance(of: address)
        let probe = try await quote(to: recipient, data: Data(), gasLimit: Self.transferGas, chainID: chainID, rpc: rpc)
        guard let amount = balance.subtracting(probe.maxCost), !amount.isZero else { throw SubmitError.nothingToSweep }
        var tx = probe.transaction
        tx.value = amount
        return Quote(transaction: tx, maxCost: balance, expectedFee: probe.expectedFee)
    }
}
