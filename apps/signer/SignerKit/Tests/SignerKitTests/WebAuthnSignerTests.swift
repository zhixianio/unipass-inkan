import CryptoKit
import Foundation
import Testing
import UniPassCore
@testable import SignerKit

@Suite struct WebAuthnSignerTests {
    let challenge = Data(hex: "0x" + String(repeating: "ab", count: 32))!

    @Test func signsAndVerifiesWithLowS() throws {
        let key = SoftwareDebugSigningKey()
        var sawHighS = false
        // 原始签名约一半是 high-s；签够多次确保两条路径都走到。
        for _ in 0..<64 {
            let signed = try WebAuthnSigner.sign(challenge: challenge, with: key)
            sawHighS = sawHighS || signed.wasHighS
            #expect(signed.signature.isLowS)
            #expect(WebAuthnSigner.verify(signed, publicKey: key.publicKey))
        }
        #expect(sawHighS)
    }

    @Test func signsTheWebAuthnMessage() throws {
        let key = SoftwareDebugSigningKey()
        let signed = try WebAuthnSigner.sign(challenge: challenge, with: key)
        // 自己按文档重拼一遍，和 core 的实现对上。
        let clientDataJSON = #"{"type":"webauthn.get","challenge":"q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s","origin":"unipass-signer://secure-enclave","crossOrigin":false}"#
        #expect(WebAuthnAssertion.signerRPID == "unipass.xyz")
        let authData = Data(SHA256.hash(data: Data(WebAuthnAssertion.signerRPID.utf8))) + Data([0x05, 0, 0, 0, 0])
        #expect(signed.assertion.authenticatorData == authData)
        let message = authData + Data(SHA256.hash(data: Data(clientDataJSON.utf8)))
        let raw = signed.signature.r.bigEndianBytes + signed.signature.s.bigEndianBytes
        #expect(key.publicKey.isValidSignature(try .init(rawRepresentation: raw), for: message))
    }

    @Test func proxySignatureLayout() throws {
        let signed = try WebAuthnSigner.sign(challenge: challenge, with: SoftwareDebugSigningKey())
        let enc = signed.proxySignature
        // head: 4 个字，r、s 在第 3、4 个字。
        #expect(enc[64..<96] == signed.signature.r.bigEndianBytes)
        #expect(enc[96..<128] == signed.signature.s.bigEndianBytes)
    }

    @Test func rejectsWrongChallengeLength() {
        #expect(throws: WebAuthnSigner.Failure.self) {
            try WebAuthnSigner.sign(challenge: Data(count: 31), with: SoftwareDebugSigningKey())
        }
    }

    @Test func publicKeyXY() {
        let key = SoftwareDebugSigningKey()
        let xy = key.publicKeyXY
        #expect(xy.x.count == 32 && xy.y.count == 32)
        #expect(Data([0x04]) + xy.x + xy.y == key.publicKey.x963Representation)
    }
}

@Suite struct BiometryPolicyTests {
    @Test func flags() {
        #expect(BiometryPolicy.anyEnrolled.flags == .biometryAny)
        #expect(BiometryPolicy.currentSet.flags == .biometryCurrentSet)
    }

    @Test func invalidationOnlyExplainedForCurrentSet() {
        // 真机上 .currentSet 密钥在 Face ID 录入变化后报的错。
        let invalidated = NSError(domain: "CryptoTokenKit", code: -3)
        #expect(BiometryPolicy.currentSet.explainsInvalidation(invalidated))
        #expect(!BiometryPolicy.anyEnrolled.explainsInvalidation(invalidated))
        #expect(!BiometryPolicy.currentSet.explainsInvalidation(NSError(domain: "com.apple.LocalAuthentication", code: -2)))
    }
}
