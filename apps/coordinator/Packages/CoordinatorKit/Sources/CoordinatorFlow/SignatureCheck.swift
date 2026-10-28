import CryptoKit
import Foundation
import UniPassCore

/// 收回 Signer 的 `unipass-signature` 后、提交 STS 之前的校验。全部通过才给出 owner 签名。
public struct SignatureCheck: Hashable, Sendable {
    public enum Item: String, CaseIterable, Hashable, Sendable {
        /// 回显的 request-id 等于这次请求的。
        case requestID
        /// s ≤ n/2。合约不拒绝 high-s，这是唯一的防线。
        case lowS
        /// authenticatorData 的 UV 位（0x04）置位，合约要求。
        case userVerified
        /// 用请求发给的那台签名器配对时保存的公钥做 P-256 验签，消息里的 challenge 用本机重算的 safeTxHash。
        /// 签名回传不带 challenge，所以验签通过同时证明：签名来自请求的那一台（不是另一台配对过的签名器），
        /// 签的就是这笔交易的 safeTxHash。
        case signatureForThisSafeTx

        /// 界面上的说法（不出现 request-id、low-s 之类的术语）。key 是英文，
        /// 译文在 App 的 String Catalog（apps/coordinator/Coordinator/Localizable.xcstrings）。
        public var title: LocalizedStringResource {
            switch self {
            case .requestID: LocalizedStringResource("It answers this request")
            case .lowS: LocalizedStringResource("The signature is in canonical form")
            case .userVerified: LocalizedStringResource("Face ID was used to sign")
            case .signatureForThisSafeTx: LocalizedStringResource("It is the requested signer's signature for this transaction")
            }
        }
    }

    public let results: [Item: Bool]
    /// 全部通过时：交给 STS / `SafeSignatures.encode` 的合约签名（owner = Signer 的 proxy）。
    public let ownerSignature: SafeOwnerSignature?

    public var passed: Bool { ownerSignature != nil }

    public init(_ signature: SignerSignature, for session: SignRequestSession) {
        var r: [Item: Bool] = [:]
        r[.requestID] = signature.requestID == session.requestID
        r[.lowS] = signature.signature.isLowS
        let authData = signature.assertion.authenticatorData
        r[.userVerified] = authData.count >= 37 && authData[authData.startIndex + 32] & 0x04 == 0x04
        r[.signatureForThisSafeTx] = Self.verifyP256(signature, challenge: session.safeTxHash, x: session.signer.x, y: session.signer.y)
        results = r
        ownerSignature = Item.allCases.allSatisfy({ r[$0] == true })
            ? .contract(owner: session.signer.signerProxy, signature: signature.proxySignature)
            : nil
    }

    /// 没通过时给界面用：这个签名是不是另一台配对过的签名器签的（拿错了手机）。
    public static func signedBy(_ signature: SignerSignature, for session: SignRequestSession, among signers: [PairedSigner]) -> PairedSigner? {
        signers.first { $0.signerProxy != session.signer.signerProxy && verifyP256(signature, challenge: session.safeTxHash, x: $0.x, y: $0.y) }
    }

    static func verifyP256(_ signature: SignerSignature, challenge: Data, x: Data, y: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y),
              let ecdsa = try? P256.Signing.ECDSASignature(
                  rawRepresentation: signature.signature.r.bigEndianBytes + signature.signature.s.bigEndianBytes)
        else { return false }
        // CryptoKit 先对消息做 SHA-256，和 Signer 的 SE 签名一致（docs/webauthn-signature.md）。
        return key.isValidSignature(ecdsa, for: signature.assertion.signingMessage(challenge: challenge))
    }
}
