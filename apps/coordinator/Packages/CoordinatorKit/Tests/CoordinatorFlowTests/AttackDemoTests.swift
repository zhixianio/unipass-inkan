#if DEBUG
import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

/// 攻击演示的三个场景：被篡改的桌面端发出的请求，经过和签名器一样的路径（二维码往返 → 解出
/// `unipass-sign-request` → core 的 RiskEngine），判定结果必须符合 docs/demo.md 里写的预期。
@Suite struct AttackDemoTests {
    let signer = SoftwareSigner()
    static let alice = Address(hex: "0xA11CE0000000000000000000000000000000a11C".lowercased())!
    static let sepoliaToken = Address(hex: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")! // Sepolia 上的 USDC（不在标签库里）

    /// 签名器那边的状态：测试 Safe 已登记，地址簿里有 Alice。
    var context: RiskContext {
        RiskContext(
            mySafes: [MySafe(registration: KnownSafes.sepoliaTestSafe)],
            addressBook: [AddressBookEntry(address: Self.alice, label: "Alice")],
            signer: SignerIdentity(keyFingerprint: signer.pairing.keyFingerprint, signerProxy: signer.proxy)
        )
    }

    /// 用户在桌面端填的那笔：给 Alice 转 0.01 ETH。
    static var shown: SafeTxRequest {
        SafeTxRequest(chainID: 11_155_111, safe: KnownSafes.sepoliaTestSafe.safe,
                      tx: SafeTx(to: alice, value: UInt256(10_000_000_000_000_000), nonce: UInt256(2)))
    }

    /// 被篡改的请求走一遍签名器的路径，返回签名器的判定。
    func assessOnSigner(_ sent: SafeTxRequest) throws -> RiskAssessment {
        let session = SignRequestSession(request: sent, signer: PairedSigner(signer.pairing), registration: KnownSafes.sepoliaTestSafe)
        let received = try SignRequestWithSafe(ur: try transmit(session.ur, dropEvery: 3))
        #expect(received.requestTargetsRegisteredSafe == true)
        return RiskEngine(context: context).assess(signRequest: received.request)
    }

    @Test func honestTransferIsNotFlagged() throws {
        let a = try assessOnSigner(Self.shown)
        #expect(a.verdict == .green)
        #expect(a.rejections.isEmpty)
    }

    @Test func bybitStyleIsRejected() throws {
        let sent = AttackDemo.bybit.tamper(Self.shown)
        #expect(sent.tx.operation == .delegateCall)
        #expect(sent.tx.to == AttackDemo.bybitImplementation)
        #expect(sent.tx.data.prefix(4) == Data([0xA9, 0x05, 0x9C, 0xBB])) // transfer(address,uint256)
        #expect(sent.safeTxHash != Self.shown.safeTxHash)
        // DELEGATECALL 到 Safe 官方库以外的合约：签名器直接拒签，没有越过的入口（docs/rules.md 硬拒）。
        let a = try assessOnSigner(sent)
        #expect(a.verdict == .rejected)
        #expect(a.rejections.map(\.reason) == [.delegateCallNotAllowed(AttackDemo.bybitImplementation)])
    }

    @Test func addressPoisoningIsRedWithR05() throws {
        let sent = AttackDemo.addressPoisoning.tamper(Self.shown)
        let fake = sent.tx.to
        #expect(fake != Self.alice)
        let fakeHex = fake.bytes.hexString, realHex = Self.alice.bytes.hexString
        #expect(fakeHex.prefix(2 + AttackDemo.poisonKeptChars) == realHex.prefix(2 + AttackDemo.poisonKeptChars))
        #expect(fakeHex.suffix(AttackDemo.poisonKeptChars) == realHex.suffix(AttackDemo.poisonKeptChars))
        let a = try assessOnSigner(sent)
        #expect(a.verdict == .red)
        #expect(a.ruleIDs.contains(.R05))
        let r05 = try #require(a.findings.first { $0.rule == .R05 })
        #expect(r05.subject == .lookalike(fake, similarTo: Self.alice))
        #expect(a.rejections.isEmpty)
    }

    @Test func addressPoisoningOfAnERC20Transfer() throws {
        let data = AttackDemo.transferCalldata(to: Self.alice, amount: UInt256(25_000_000))
        let shown = SafeTxRequest(chainID: 11_155_111, safe: KnownSafes.sepoliaTestSafe.safe,
                                  tx: SafeTx(to: Self.sepoliaToken, data: data, nonce: UInt256(2)))
        let sent = AttackDemo.addressPoisoning.tamper(shown)
        #expect(sent.tx.to == Self.sepoliaToken) // 代币合约不变，只换收款人
        #expect(AttackDemo.erc20Recipient(sent.tx)?.recipient == AttackDemo.lookalike(of: Self.alice))
        #expect(AttackDemo.erc20Recipient(sent.tx)?.amount == UInt256(25_000_000))
        let a = try assessOnSigner(sent)
        #expect(a.verdict == .red)
        #expect(a.ruleIDs.contains(.R05))
    }

    @Test func refundDrainIsRejected() throws {
        let sent = AttackDemo.refundDrain.tamper(Self.shown)
        #expect(sent.tx.to == Self.shown.tx.to && sent.tx.value == Self.shown.tx.value) // 交易本身没变
        let a = try assessOnSigner(sent)
        #expect(a.verdict == .rejected)
        #expect(a.rejections.map(\.reason) == [.gasRefundNotSupported(
            gasPrice: UInt256(1_000_000_000_000), baseGas: UInt256(1_000_000), gasToken: .zero, refundReceiver: AttackDemo.attacker)])
    }

    @Test func lookalikeKeepsEndsAndChangesEveryMiddleDigit() {
        for a in [Self.alice, KnownSafes.sepoliaTestSafe.safe, Address(hex: "0x000000000000000000000000000000000000bEEF")!] {
            let l = Array(AttackDemo.lookalike(of: a).bytes.hexString.dropFirst(2))
            let o = Array(a.bytes.hexString.dropFirst(2))
            let k = AttackDemo.poisonKeptChars
            #expect(l[..<k] == o[..<k] && l[(40 - k)...] == o[(40 - k)...])
            #expect((k ..< 40 - k).allSatisfy { l[$0] != o[$0] })
        }
    }
}
#endif
