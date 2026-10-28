import CryptoKit
import Foundation
import Testing
@testable import UniPassCore

struct WebAuthnSignatureTests {
    let challenge = Data(hex: "0x9f2c3b1c5e7a0d4f6b8e1a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60")!

    @Test func clientDataJSONMatchesContractReconstruction() {
        let json = WebAuthnAssertion.signerDefault.clientDataJSON(challenge: challenge)
        #expect(String(decoding: json, as: UTF8.self) ==
            #"{"type":"webauthn.get","challenge":"nyw7HF56DU9rjhosPU5fYHGCk6S1xtfo-QobLD1OX2A","origin":"unipass-signer://secure-enclave","crossOrigin":false}"#)
    }

    @Test func defaultAuthenticatorData() {
        let auth = WebAuthnAssertion.signerDefault.authenticatorData
        #expect(auth.count == 37)
        #expect(auth.prefix(32) == Data(SHA256.hash(data: Data("unipass.xyz".utf8))))
        #expect(auth[32] == 0x05)
    }

    @Test func base64URLHasNoPadding() {
        #expect(Base64URL.encode(Data([0xFB, 0xFF])) == "-_8")
        #expect(Base64URL.encode(Data()) == "")
    }

    /// 用软件 P-256 密钥走一遍 Signer 的签名流程（SE 密钥产出的签名格式相同）。
    @Test func signedAssertionVerifiesAfterLowSNormalization() throws {
        let key = P256.Signing.PrivateKey()
        let assertion = WebAuthnAssertion.signerDefault
        let message = assertion.signingMessage(challenge: challenge)

        for _ in 0..<20 {
            let raw = try key.signature(for: message).rawRepresentation
            let sig = try #require(P256Signature(raw: raw)).normalizedToLowS
            #expect(sig.isLowS)

            let roundTrip = try P256.Signing.ECDSASignature(rawRepresentation: sig.r.bigEndianBytes + sig.s.bigEndianBytes)
            #expect(key.publicKey.isValidSignature(roundTrip, for: message))
        }
    }

    @Test func lowSNormalization() throws {
        let n = P256Signature.curveOrder
        let high = P256Signature(r: UInt256(1), s: try #require(n.subtracting(UInt256(5))))
        #expect(!high.isLowS)
        #expect(high.normalizedToLowS.s == UInt256(5))

        let half = P256Signature(r: UInt256(1), s: P256Signature.halfOrder)
        #expect(half.isLowS)
        #expect(half.normalizedToLowS == half)
    }
}
