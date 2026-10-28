import CryptoKit
import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

/// 用软件 P-256 密钥模拟 Signer，按 Signer 的做法（apps/signer 的 `WebAuthnSigner.sign`）解析请求、签名、回传。
struct SoftwareSigner {
    let key = P256.Signing.PrivateKey()
    var name = "Test Signer"
    var policy: SignerBiometryPolicy? = .anyEnrolled
    var proxy = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!

    var pairing: SignerPairing {
        let raw = key.publicKey.rawRepresentation
        return SignerPairing(
            x: raw.prefix(32), y: raw.suffix(32), name: name, biometryPolicy: policy, signerProxy: proxy,
            verifiers: Data(hex: "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")!,
            signerFactory: Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!
        )
    }

    enum Refusal: Error { case notForMe }

    /// Signer 端：解析 `eth-sign-request`、核对是不是发给自己、签名、回传 `unipass-signature`。
    func sign(_ request: EthSignRequest, assertion: WebAuthnAssertion = .signerDefault) throws -> SignerSignature {
        let parsed = try SafeTxRequest(signRequest: request)
        guard request.derivationPath.components.isEmpty,
              request.derivationPath.sourceFingerprint == pairing.keyFingerprint,
              request.address == proxy
        else { throw Refusal.notForMe }
        return try sign(challenge: parsed.safeTxHash, requestID: request.requestID!, assertion: assertion)
    }

    func sign(challenge: Data, requestID: Data, assertion: WebAuthnAssertion = .signerDefault) throws -> SignerSignature {
        let raw = try key.signature(for: assertion.signingMessage(challenge: challenge)).rawRepresentation
        return SignerSignature(requestID: requestID, assertion: assertion, signature: P256Signature(raw: raw)!.normalizedToLowS)
    }
}

/// 把 UR 编成多帧再解回来（模拟二维码往返；喷泉码，随机丢掉一部分帧）。
func transmit(_ ur: UR, maxFragmentLen: Int = 200, dropEvery: Int = 0) throws -> UR {
    var encoder = UREncoder(ur, maxFragmentLen: maxFragmentLen)
    var decoder = URDecoder()
    var i = 0
    while decoder.result == nil {
        let part = encoder.nextPart().uppercased() // 二维码里是大写
        i += 1
        if dropEvery > 0, i % dropEvery == 0 { continue }
        try decoder.receive(part)
        if i > 10_000 { Issue.record("没有收齐"); break }
    }
    return try decoder.result!.get()
}

let testSafe = KnownSafes.sepoliaTestSafe.safe

func transferRequest(nonce: UInt64 = 1) -> SafeTxRequest {
    SafeTxRequest(chainID: 11_155_111, safe: testSafe,
                  tx: SafeTx(to: Address(hex: "0x000000000000000000000000000000000000bEEF")!, value: UInt256(1), nonce: UInt256(nonce)))
}

@Suite struct PairingTests {
    @Test func pairingRoundTripAndStorage() throws {
        let signer = SoftwareSigner(policy: .currentSet)
        let ur = try transmit(signer.pairing.ur)
        let paired = PairedSigner(try SignerPairing(ur: ur))
        #expect(paired.pairing == signer.pairing)
        #expect(paired.keyFingerprint == signer.pairing.keyFingerprint)
        #expect(paired.fingerprintText.count == 9)
        #expect(paired.biometryNotice != nil)
        // 保存后读回不变（存 UserDefaults 用 JSON）。
        let decoded = try JSONDecoder().decode(PairedSigner.self, from: JSONEncoder().encode(paired))
        #expect(decoded == paired)
    }

    @Test func groupedAddressMatchesSignerDisplay() {
        let a = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!
        #expect(PairedSigner.groupedAddress(a) == "c8F9 e2ba 66e6 40B0 5D6d 8DA4 f00f 5676 79bc 9A06")
    }

    @Test func ownerMargin() {
        #expect(!PairedSigner.hasMarginWithoutThisSigner(owners: 2, threshold: 2))
        #expect(PairedSigner.hasMarginWithoutThisSigner(owners: 3, threshold: 2))
    }
}

@Suite struct SignRoundTripTests {
    let signer = SoftwareSigner()

    func session(_ request: SafeTxRequest = transferRequest()) -> SignRequestSession {
        SignRequestSession(request: request, signer: PairedSigner(signer.pairing), registration: KnownSafes.sepoliaTestSafe)
    }

    @Test func requestFollowsConventions() throws {
        let s = session()
        let req = try SignRequestWithSafe(ur: try transmit(s.ur)).request
        #expect(req == s.signRequest)
        #expect(req.dataType == .typedData)
        #expect(req.requestID?.count == 16)
        #expect(req.chainID == 11_155_111)
        #expect(req.derivationPath.components.isEmpty)
        #expect(req.derivationPath.sourceFingerprint == signer.pairing.keyFingerprint)
        #expect(req.address == signer.proxy)
        // sign-data 就是规范 JSON，Signer 解析后哈希一致。
        #expect(String(decoding: req.signData, as: UTF8.self) == s.request.canonicalJSON)
        #expect(try SafeTxRequest(signRequest: req).safeTxHash == s.safeTxHash)
    }

    @Test func fullRoundTripPasses() throws {
        let s = session()
        let received = try SignRequestWithSafe(ur: try transmit(s.ur, dropEvery: 3)).request
        let reply = try signer.sign(received)
        let back = try SignerSignature(ur: try transmit(reply.ur, dropEvery: 4))
        let check = SignatureCheck(back, for: s)
        #expect(check.passed)
        #expect(SignatureCheck.Item.allCases.allSatisfy { check.results[$0] == true })
        guard case .contract(let owner, let sig)? = check.ownerSignature else {
            Issue.record("没有合约签名")
            return
        }
        #expect(owner == signer.proxy)
        #expect(sig == back.proxySignature)
        // 能和其他 owner 的签名一起拼成 execTransaction 的 signatures。
        let eoa = SafeOwnerSignature.eoa(owner: Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!,
                                         signature: Data(repeating: 1, count: 64) + Data([27]))
        #expect(try SafeSignatures.encode([check.ownerSignature!, eoa]).count == 65 * 2 + 32 + sig.count)
    }

    @Test func signerRefusesRequestForAnotherSigner() throws {
        let s = SignRequestSession(request: transferRequest(), signer: PairedSigner(SoftwareSigner().pairing),
                                   registration: KnownSafes.sepoliaTestSafe)
        #expect(throws: SoftwareSigner.Refusal.self) { try signer.sign(s.signRequest) }
    }

    /// 二维码一律发 `unipass-sign-request`，core 的解码器解出的两部分都和发出去的一致。
    @Test func signRequestCarriesTheSafeRegistration() throws {
        let s = session()
        #expect(s.ur.type == SignRequestWithSafe.urType)
        #expect(s.ur.cbor.prefix(4) == Data([0xA2, 0x01, 0xD9, 0x01])) // a2 01 d9 0191 …（docs/ur-types.md）
        let back = try SignRequestWithSafe(ur: try transmit(s.ur, dropEvery: 4))
        #expect(back.request == s.signRequest)
        #expect(back.registration == KnownSafes.sepoliaTestSafe)
        #expect(back.requestTargetsRegisteredSafe == true)
        #expect(try back.registration.verified().version == "1.4.1")
        #expect(try SafeTxRequest(signRequest: back.request).safeTxHash == s.safeTxHash)
    }

    /// 帧数：测试 Safe 的一笔普通转账。
    @Test func frameCountForATransfer() throws {
        let s = session(transferRequest(nonce: 2))
        let plain = UREncoder(s.signRequest.ur, maxFragmentLen: 200)
        let wrapped = UREncoder(s.ur, maxFragmentLen: 200)
        print("eth-sign-request: \(s.signRequest.ur.cbor.count) B CBOR, \(plain.seqLen) parts; unipass-sign-request: \(s.ur.cbor.count) B CBOR, \(wrapped.seqLen) parts")
        #expect(wrapped.seqLen > plain.seqLen)
        #expect(wrapped.seqLen <= 8)
    }

    // MARK: 反例：被篡改或不对应的签名必须被拒绝

    @Test func tamperedRIsRejected() throws {
        let s = session()
        var reply = try signer.sign(s.signRequest)
        var r = reply.signature.r.bigEndianBytes
        r[31] ^= 0x01
        reply.signature = P256Signature(r: UInt256(bigEndian: r)!, s: reply.signature.s)
        let check = SignatureCheck(reply, for: s)
        #expect(!check.passed)
        #expect(check.results[.signatureForThisSafeTx] == false)
        #expect(check.ownerSignature == nil)
    }

    @Test func tamperedClientDataFieldsIsRejected() throws {
        let s = session()
        var reply = try signer.sign(s.signRequest)
        reply.assertion.clientDataFields = #""origin":"https://evil.example","crossOrigin":false"#
        #expect(!SignatureCheck(reply, for: s).passed)
    }

    @Test func wrongRequestIDIsRejected() throws {
        let s = session()
        let reply = try signer.sign(challenge: s.safeTxHash, requestID: SignRequestSession.randomRequestID())
        let check = SignatureCheck(reply, for: s)
        #expect(check.results[.requestID] == false)
        #expect(check.results[.signatureForThisSafeTx] == true)
        #expect(!check.passed)
    }

    @Test func signatureForAnotherTransactionIsRejected() throws {
        let s = session(transferRequest(nonce: 1))
        let other = transferRequest(nonce: 2)
        let reply = try signer.sign(challenge: other.safeTxHash, requestID: s.requestID)
        let check = SignatureCheck(reply, for: s)
        #expect(check.results[.requestID] == true)
        #expect(check.results[.signatureForThisSafeTx] == false)
        #expect(!check.passed)
    }

    @Test func signatureFromAnotherKeyIsRejected() throws {
        let s = session()
        let reply = try SoftwareSigner().sign(challenge: s.safeTxHash, requestID: s.requestID)
        #expect(SignatureCheck(reply, for: s).results[.signatureForThisSafeTx] == false)
    }

    @Test func highSIsRejected() throws {
        let s = session()
        var reply = try signer.sign(s.signRequest)
        reply.signature = P256Signature(r: reply.signature.r, s: P256Signature.curveOrder.subtracting(reply.signature.s)!)
        let check = SignatureCheck(reply, for: s)
        #expect(check.results[.lowS] == false)
        #expect(check.results[.signatureForThisSafeTx] == true) // high-s 本身是有效的 ECDSA 签名
        #expect(!check.passed)
        // core 的解码也拒绝 high-s。
        #expect(throws: (any Error).self) { try SignerSignature(ur: reply.ur) }
    }

    @Test func missingUserVerificationIsRejected() throws {
        let s = session()
        var authData = WebAuthnAssertion.signerDefault.authenticatorData
        authData[authData.startIndex + 32] = 0x01 // 只有 UP
        let assertion = WebAuthnAssertion(authenticatorData: authData, clientDataFields: WebAuthnAssertion.signerDefault.clientDataFields)
        let reply = try signer.sign(s.signRequest, assertion: assertion)
        let check = SignatureCheck(reply, for: s)
        #expect(check.results[.userVerified] == false)
        #expect(check.results[.signatureForThisSafeTx] == true)
        #expect(!check.passed)
    }

    @Test func corruptedFrameIsDetected() throws {
        let s = session()
        let reply = try signer.sign(s.signRequest)
        var text = reply.ur.string
        // 改坏 bytewords 里的一个字母：CRC32 校验和不对，解码失败。
        let i = text.index(text.endIndex, offsetBy: -20)
        text.replaceSubrange(i...i, with: text[i] == "a" ? "e" : "a")
        #expect(throws: (any Error).self) { try UR(parsing: text) }
    }
}

@Suite struct SafeRegistrationTests {
    @Test func testSafeParametersRecomputeTheAddress() throws {
        let r = KnownSafes.sepoliaTestSafe
        let ic = try r.verified()
        #expect(ic.version == "1.4.1")
        #expect(ic.isL2)
        let back = try SafeRegistration(ur: try transmit(r.ur))
        #expect(back == r)
        #expect(SafeAddress.compute(back) == r.safe)
    }

    @Test func tamperedOwnerChangesTheAddress() throws {
        var r = KnownSafes.sepoliaTestSafe
        r.owners[1] = Address(hex: "0x0000000000000000000000000000000000001234")!
        #expect(throws: SafeAddress.VerificationError.self) { try r.verified() }
    }
}

@Suite struct ExecTransactionTests {
    /// Sepolia 上实际执行成功的那笔（第一笔由 iPhone 签名的交易，0x1e546e1c…e3d2）：重新编码必须逐字节相同。
    @Test func matchesExecutedSepoliaCalldata() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/exec-sepolia-0x1e546e1c.hex")
        let onChain = try #require(Data(hex: try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let tx = SafeTx(to: Address(hex: "0x000000000000000000000000000000000000bEEF")!, data: Data([0x01]), nonce: .zero)
        // 取出链上那笔用的 signatures（第 10 个参数），其余参数由我们自己编码。
        let values = try #require(ABICodec.decode(
            [.address, .uint(256), .bytes, .uint(8), .uint(256), .uint(256), .uint(256), .address, .address, .bytes],
            onChain.dropFirst(4)))
        let signatures = try #require(values[9].bytes)
        #expect(signatures.count == 482)
        #expect(ExecTransaction.calldata(tx, signatures: signatures) == onChain)
    }
}

@Suite struct AddressHighlightTests {
    /// 高亮前 8 位、后 8 位（10 组里的第 1、2、9、10 组）。
    @Test func highlightsFirstAndLastEightHexDigits() {
        let groups = PairedSigner.addressGroups(Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!)
        #expect(groups.count == 10)
        let highlighted = groups.indices.filter { PairedSigner.isHighlightedGroup($0, of: groups.count) }.map { groups[$0] }.joined()
        #expect(highlighted == "c8F9e2ba" + "79bc9A06")
    }
}
