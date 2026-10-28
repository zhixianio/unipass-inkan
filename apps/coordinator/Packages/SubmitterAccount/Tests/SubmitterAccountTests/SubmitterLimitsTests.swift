import Foundation
import SafeTransactionService
import Testing
import UniPassCore
@testable import SubmitterAccount

/// 节点不可信（包括默认的公共节点）：chainId、gas、小费都由它报，提交账户签名前要自己卡住。
@Suite(.serialized) struct SubmitterRPCTests {
    static let sepolia: UInt64 = 11_155_111
    let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
    var exec: Data { SigningPolicy.execTransaction + Data(count: 64) }

    var account: SubmitterAccount {
        SubmitterAccount(key: try! Secp256k1Key(Vectors.privateKey),
                         policy: SigningPolicy(safes: [.init(chainID: Self.sepolia, address: safe)]))
    }

    /// "Sepolia"节点谎报 chainId = 1：同一把私钥不能因此签出一笔主网交易。不签，什么都不发。
    @Test func refusesANodeOnAnotherChain() async throws {
        MockRPC.honestSepolia()
        MockRPC.results["eth_chainId"] = "0x1"
        await #expect(throws: SubmitterAccount.SubmitError.wrongChain(expected: Self.sepolia, reported: 1)) {
            _ = try await account.quote(to: safe, data: exec, chainID: Self.sepolia, rpc: MockRPC.rpc())
        }
        await #expect(throws: SubmitterAccount.SubmitError.wrongChain(expected: Self.sepolia, reported: 1)) {
            _ = try await account.sweepQuote(to: Vectors.address, chainID: Self.sepolia, rpc: MockRPC.rpc())
        }
        #expect(MockRPC.sentRaw.isEmpty)
    }

    /// 节点报天价小费（0.01 ETH / gas）想把余额都变成小费：小费压到上限，最多花费跟着有上限。
    @Test func capsTheTip() async throws {
        MockRPC.honestSepolia()
        MockRPC.results["eth_maxPriorityFeePerGas"] = "0x2386f26fc10000"
        let q = try await account.quote(to: safe, data: exec, chainID: Self.sepolia, rpc: MockRPC.rpc())
        #expect(q.transaction.maxPriorityFeePerGas == SigningPolicy.maxTip)
        #expect(q.transaction.maxFeePerGas == UInt256(2 * 1_000_000_000 + 2_000_000_000))
        #expect(q.transaction.gasLimit == 250_000)
        #expect(q.maxCost == UInt256(250_000 * 4_000_000_000))
    }

    /// 正常的节点照常报价。
    @Test func honestNode() async throws {
        MockRPC.honestSepolia()
        let q = try await account.quote(to: safe, data: exec, chainID: Self.sepolia, rpc: MockRPC.rpc())
        #expect(q.transaction.chainID == Self.sepolia)
        #expect(q.transaction.maxPriorityFeePerGas == UInt256(100_000_000))
        #expect(q.transaction.maxFeePerGas == UInt256(2_100_000_000))
        _ = try await account.send(q, rpc: MockRPC.rpc())
        #expect(MockRPC.sentRaw.count == 1)
    }

    /// estimateGas 报得离谱：超过硬上限，或者最多花费超过本地估算的 4 倍，都不签。
    @Test func refusesInflatedGas() async throws {
        MockRPC.honestSepolia(estimateGas: 10_000_000)
        await #expect(throws: SigningPolicy.Violation.gasLimitTooHigh) {
            _ = try await account.quote(to: safe, data: exec, chainID: Self.sepolia, rpc: MockRPC.rpc())
        }
        // 1.25M 在硬上限以内，但 1.25M × 2.1 gwei 是本地估算 400k × 1.1 gwei 的 6 倍。
        MockRPC.honestSepolia(estimateGas: 1_000_000)
        await #expect(throws: SubmitterAccount.SubmitError.costAboveEstimate) {
            _ = try await account.quote(to: safe, data: exec, chainID: Self.sepolia, rpc: MockRPC.rpc())
        }
        #expect(MockRPC.sentRaw.isEmpty)
    }

    /// baseFee 报得离谱：maxFee 超过绝对上限，不签。
    @Test func refusesAbsurdBaseFee() async throws {
        MockRPC.honestSepolia()
        MockRPC.results["eth_getBlockByNumber"] = ["baseFeePerGas": "0xe8d4a51000"] // 1000 gwei
        await #expect(throws: SigningPolicy.Violation.feeTooHigh) {
            _ = try await account.quote(to: safe, data: exec, chainID: Self.sepolia, rpc: MockRPC.rpc())
        }
    }
}

@Suite struct SigningLimitsTests {
    static let sepolia: UInt64 = 11_155_111
    let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
    var policy: SigningPolicy { SigningPolicy(safes: [.init(chainID: Self.sepolia, address: safe)]) }
    var exec: Data { SigningPolicy.execTransaction + Data(count: 64) }

    func tx(chainID: UInt64 = sepolia, to: Address, data: Data = Data(), gas: UInt64, tip: UInt64 = 1_000_000_000,
            maxFee: UInt64 = 3_000_000_000) -> EIP1559Transaction {
        EIP1559Transaction(chainID: chainID, nonce: 0, maxPriorityFeePerGas: UInt256(tip), maxFeePerGas: UInt256(maxFee),
                           gasLimit: gas, to: to, data: data)
    }

    /// 白名单按 (链, 地址) 匹配：同一个地址在没登记的链上不签；不支持的链一律不签。
    @Test func safesAreMatchedPerChain() throws {
        try policy.check(tx(to: safe, data: exec, gas: 300_000))
        #expect(throws: SigningPolicy.Violation.notAllowed) { try policy.check(tx(chainID: 1, to: safe, data: exec, gas: 300_000)) }
        #expect(throws: SigningPolicy.Violation.notAllowed) { try policy.check(tx(chainID: 8453, to: safe, data: exec, gas: 300_000)) }
        #expect(throws: SigningPolicy.Violation.wrongChain) { try policy.check(tx(chainID: 10, to: safe, data: exec, gas: 300_000)) }
        #expect(throws: SigningPolicy.Violation.wrongChain) { try policy.check(tx(chainID: 10, to: Vectors.address, gas: 21_000)) }
    }

    @Test func gasLimits() throws {
        try policy.check(tx(to: safe, data: exec, gas: SigningPolicy.executionGasLimit))
        #expect(throws: SigningPolicy.Violation.gasLimitTooHigh) {
            try policy.check(tx(to: safe, data: exec, gas: SigningPolicy.executionGasLimit + 1))
        }
        try policy.check(tx(to: Vectors.address, gas: 21_000))
        #expect(throws: SigningPolicy.Violation.gasLimitTooHigh) { try policy.check(tx(to: Vectors.address, gas: 21_001)) }
        // 部署：按批量里的签名器个数算。
        let one = SigningPolicyTests.batch([SigningPolicyTests.entry(SigningPolicy.signerFactory, SigningPolicyTests.createSigner),
                                            SigningPolicyTests.entry(SigningPolicy.proxyFactory141, SigningPolicyTests.createProxy())])
        let limit = SigningPolicy.deploymentGasLimit(signers: 1)
        #expect(limit == 3_500_000)
        try policy.check(tx(to: SigningPolicy.multiSendCallOnly141, data: one, gas: limit))
        #expect(throws: SigningPolicy.Violation.gasLimitTooHigh) {
            try policy.check(tx(to: SigningPolicy.multiSendCallOnly141, data: one, gas: limit + 1))
        }
    }

    @Test func feeLimits() throws {
        try policy.check(tx(to: safe, data: exec, gas: 300_000, tip: 2_000_000_000, maxFee: 500_000_000_000))
        #expect(throws: SigningPolicy.Violation.feeTooHigh) {
            try policy.check(tx(to: safe, data: exec, gas: 300_000, tip: 2_000_000_001))
        }
        #expect(throws: SigningPolicy.Violation.feeTooHigh) {
            try policy.check(tx(to: safe, data: exec, gas: 300_000, maxFee: 500_000_000_001))
        }
        #expect(throws: SigningPolicy.Violation.feeTooHigh) { try policy.check(tx(to: Vectors.address, gas: 21_000, tip: 2_000_000_000, maxFee: 1_000_000_000)) }
    }
}
