import Foundation
import Testing
@testable import UniPassCore

struct SigningGateTests {
    typealias F = Fixture
    static let id = SignerIdentity(keyFingerprint: 0x7A6D_6628, signerProxy: Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!)

    static func signRequest(_ tx: SafeTx, fingerprint: UInt32 = id.keyFingerprint, address: Address? = nil) -> EthSignRequest {
        let req = SafeTxRequest(chainID: F.chain, safe: F.safe, tx: tx)
        return EthSignRequest(requestID: Data(repeating: 7, count: 16), signData: Data(req.canonicalJSON.utf8), dataType: .typedData,
                              chainID: F.chain, derivationPath: CryptoKeypath(components: [], sourceFingerprint: fingerprint), address: address)
    }

    static var engine: RiskEngine {
        var c = F.context()
        c.signer = id
        return RiskEngine(context: c)
    }

    @Test func greenSignsWithRecomputedHash() throws {
        let tx = SafeTx(to: F.alice, value: UInt256(1), nonce: UInt256(9))
        let a = Self.engine.assess(signRequest: Self.signRequest(tx))
        let s = try SignableTransaction(a)
        #expect(s.challenge == SafeTxRequest(chainID: F.chain, safe: F.safe, tx: tx).safeTxHash)
        #expect(s.requestID == Data(repeating: 7, count: 16))
    }

    /// 伪造：拿一个被拒的 assessment（带着 request）去签，必须失败。
    @Test func rejectedAssessmentCannotBeSigned() throws {
        var a = Self.engine.assess(signRequest: Self.signRequest(SafeTx(to: F.alice, value: UInt256(1), nonce: .zero)))
        #expect(a.verdict == .green)
        a.rejections.append(Rejection(reason: .networkOnline, explanation: Explanation("reject.networkOnline")))
        #expect(a.request != nil)
        #expect(throws: SignableTransaction.Refusal.rejected([.networkOnline])) { try SignableTransaction(a) }
        // 真实的被拒：Safe 没登记。
        let unregistered = RiskEngine(context: F.context(safes: [])).assess(signRequest: Self.signRequest(SafeTx(to: F.alice, nonce: .zero)))
        #expect(unregistered.request != nil)
        #expect(throws: SignableTransaction.Refusal.self) { try SignableTransaction(unregistered, confirmation: "anything") }
    }

    @Test func requestMustTargetThisSigner() {
        let tx = SafeTx(to: F.alice, value: UInt256(1), nonce: .zero)
        #expect(Self.engine.assess(signRequest: Self.signRequest(tx, fingerprint: 1)).rejections.map(\.reason) == [.notForThisSigner])
        #expect(Self.engine.assess(signRequest: Self.signRequest(tx, address: F.alice)).rejections.map(\.reason) == [.notForThisSigner])
        #expect(Self.engine.assess(signRequest: Self.signRequest(tx, address: Self.id.signerProxy)).verdict == .green)
    }

    @Test func missingRequestIDCannotBeSigned() {
        let a = RiskEngine(context: F.context()).assess(SafeTxRequest(chainID: F.chain, safe: F.safe, tx: SafeTx(to: F.alice, nonce: .zero)))
        #expect(throws: SignableTransaction.Refusal.missingRequestID) { try SignableTransaction(a) }
    }

    @Test func redNeedsRiskSpecificPhrase() throws {
        // SafeMigration 1.4.1：仍然允许 DELEGATECALL 的官方升级库，判 R01 红。
        let target = Address(hex: "0x526643F69b81B008F46d95CD5ced5eC0edFFDaC6")!
        let a = Self.engine.assess(signRequest: Self.signRequest(SafeTx(to: target, operation: .delegateCall, nonce: .zero)))
        #expect(a.verdict == .red)
        #expect(ConfirmationPhrase(a).tokens.map(\.expected) == ["DAC6"])
        #expect(throws: SignableTransaction.Refusal.confirmationRequired) { try SignableTransaction(a) }
        #expect(throws: SignableTransaction.Refusal.confirmationMismatch) { try SignableTransaction(a, confirmation: "我确认") }
        #expect(throws: SignableTransaction.Refusal.confirmationMismatch) { try SignableTransaction(a, confirmation: "DAC6 DAC6") }
        _ = try SignableTransaction(a, confirmation: " 0xdac6 ")
        // Bybit 那种 DELEGATECALL 到陌生合约：硬拒，给确认字符也签不了。
        let bybit = Address(hex: "0x96221423681A6d52E184D440a8eFCEbB105C7242")!
        let r = Self.engine.assess(signRequest: Self.signRequest(SafeTx(to: bybit, operation: .delegateCall, nonce: .zero)))
        #expect(r.verdict == .rejected)
        #expect(throws: SignableTransaction.Refusal.self) { try SignableTransaction(r, confirmation: "7242") }
        // 多条红：每条都要输入，顺序不限。
        let unlimited = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.aliceLookalike), .uint(F.max256)])
        let ms = F.multiSend([(1, target, .zero, Data()), (0, F.usdc, .zero, unlimited)])
        let b = Self.engine.assess(signRequest: Self.signRequest(SafeTx(to: F.ms141, data: ms, operation: .delegateCall, nonce: .zero)))
        // aliceLookalike = 0x1119999…9111 和 alice = 0x1111…1111 从第 4 位（下标 3）开始不同：R05 要输入 "9999"。
        #expect(Set(ConfirmationPhrase(b).tokens.map(\.expected)) == ["DAC6", "9111", "9999"])
        _ = try SignableTransaction(b, confirmation: "9111, dac6 9999")
        #expect(throws: SignableTransaction.Refusal.confirmationMismatch) { try SignableTransaction(b, confirmation: "9111 DAC6") }
        // 改门限：要求输入新门限。
        let ct = F.call("changeThreshold(uint256)", [.uint(256)], [.uint(UInt256(1))])
        let c = Self.engine.assess(signRequest: Self.signRequest(SafeTx(to: F.safe, data: ct, nonce: .zero)))
        #expect(ConfirmationPhrase(c).tokens.map(\.expected) == ["1"])
    }

    /// 首尾各 6 位相同的一对地址（地址投毒）：旧的"后 4 位"短语不能通过，必须输入第一处不同开始的 4 位。
    @Test func lookalikePhraseUsesFirstDifference() throws {
        let real = Address(hex: "0xab12cd0000000000000000000000000000ef3456")!
        let fake = Address(hex: "0xab12cd7777777777777777777777777777ef3456")!
        let book = [AddressBookEntry(address: real, label: "Exchange")]
        var ctx = RiskContext(mySafes: [MySafe(chainID: F.chain, address: F.safe)], addressBook: book, labels: F.library)
        ctx.signer = Self.id
        let a = RiskEngine(context: ctx).assess(signRequest: Self.signRequest(SafeTx(to: fake, value: UInt256(1), nonce: .zero)))
        #expect(a.findings.map(\.rule) == [.R05])
        let phrase = ConfirmationPhrase(a)
        #expect(phrase.tokens.map(\.expected) == ["7777"])
        #expect(ConfirmationPhrase.differenceWindow(fake, real) == (6, 6))
        // 旧方案：后 4 位（两边一样）。
        #expect(throws: SignableTransaction.Refusal.confirmationMismatch) { try SignableTransaction(a, confirmation: "3456") }
        // 前 4 位也一样，也不能通过。
        #expect(throws: SignableTransaction.Refusal.confirmationMismatch) { try SignableTransaction(a, confirmation: "AB12") }
        _ = try SignableTransaction(a, confirmation: "7777")
        // 不同只出现在最后几位时，窗口往前挪，仍然包含不同的那一位。
        let tailOnly = Address(hex: "0xab12cd0000000000000000000000000000ef3457")!
        let w = ConfirmationPhrase.differenceWindow(tailOnly, real)
        #expect(w.firstDifference == 39 && w.start == 36)
    }

    @Test func ownerChangePreview() {
        let me = Self.id.signerProxy
        let eoa = Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!
        let safe = MySafe(chainID: F.chain, address: F.safe, owners: [me, eoa], threshold: 2)
        func assess(_ data: Data) -> RiskAssessment {
            RiskEngine(context: RiskContext(mySafes: [safe], addressBook: [], labels: F.library))
                .assess(SafeTxRequest(chainID: F.chain, safe: F.safe, tx: SafeTx(to: F.safe, data: data, nonce: .zero)))
        }
        let add = F.call("addOwnerWithThreshold(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(2))])
        let p = OwnerChangePreview(assess(add), safe: safe, thisSigner: me)!
        #expect(p.afterOwners == [F.alice, me, eoa] && p.afterThreshold == 2 && p.added == [F.alice] && p.warnings.isEmpty)
        let swapMe = F.call("swapOwner(address,address,address)", [.address, .address, .address],
                            [.address(Address(hex: "0x0000000000000000000000000000000000000001")!), .address(me), .address(F.alice)])
        let q = OwnerChangePreview(assess(swapMe), safe: safe, thisSigner: me)!
        #expect(q.afterOwners == [F.alice, eoa] && q.removed == [me] && q.warnings == [.thresholdEqualsOwners, .removesThisSigner])
        let one = F.call("changeThreshold(uint256)", [.uint(256)], [.uint(UInt256(1))])
        #expect(OwnerChangePreview(assess(one), safe: safe)!.warnings == [.singleSignature])
        let three = F.call("changeThreshold(uint256)", [.uint(256)], [.uint(UInt256(3))])
        #expect(OwnerChangePreview(assess(three), safe: safe)!.warnings == [.thresholdExceedsOwners])
        let removeStranger = F.call("removeOwner(address,address,uint256)", [.address, .address, .uint(256)],
                                    [.address(me), .address(F.stranger), .uint(UInt256(1))])
        #expect(OwnerChangePreview(assess(removeStranger), safe: safe)!.warnings.contains(.ownerNotInRecord(F.stranger)))
        // 不改 owner 的交易没有预览。
        #expect(OwnerChangePreview(assess(F.call("setGuard(address)", [.address], [.address(.zero)])), safe: safe) == nil)
    }
}
