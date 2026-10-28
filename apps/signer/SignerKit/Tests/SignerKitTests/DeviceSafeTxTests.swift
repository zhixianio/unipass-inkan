import Foundation
import Testing
import UniPassCore

/// contracts/ 的 fork 测试（test_deviceSafeTx）要真机签的那笔 SafeTx。
/// Signer 签名前要自己重算 safeTxHash，这里先确认 core 算出来的和 contracts（cast）一致。
@Suite struct DeviceSafeTxTests {
    let to = Address(hex: "0x000000000000000000000000000000000000BEEF")!
    let sepolia = UInt256(11_155_111)

    /// rpId unipass.xyz、xyz.unipass.signer 的 SE 密钥对应的 fork Safe。
    @Test func recomputesContractsSafeTxHash() {
        let tx = SafeTx(to: to, value: UInt256(1), nonce: .zero)
        let hash = tx.hash(chainId: sepolia, safe: Address(hex: "0xE8982BeA17b5959D7bDA9571f0c183914B8B06Db")!)
        #expect(hash.hexString == "0xedc1403872e38762c0f7832dde77fc5da03ff4684044761d617a30a1ecf4198d")
    }

    /// coordinator-m0 测 STS 写入用的测试 Safe（SafeL2 1.4.1，contracts-m0 部署）。
    @Test func recomputesCoordinatorStsHashes() {
        let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
        let a = SafeTx(to: to, nonce: .zero).hash(chainId: sepolia, safe: safe)
        #expect(a.hexString == "0xf95f70e8cd3ac490f3da251b22f37e4bdd813b400a3a5606d02822b10e37799a")
        let b = SafeTx(to: to, data: Data([0x01]), nonce: .zero).hash(chainId: sepolia, safe: safe)
        #expect(b.hexString == "0x4f3511cb2bdc1faa27c6af57461885a955075267776e0bb442e4c30ba8b47850")
    }
}
