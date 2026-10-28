import CryptoKit
import Foundation
import LocalAuthentication
import UniPassCore

/// "我的 Safe"和地址簿的签名：每次改动都用签名密钥签一次（SE 密钥会弹 Face ID），签名和数据存在一起，加载时验签。
///
/// 签的消息是 65 字节：
///
///     tag(32) ‖ 0x00 ‖ sha256(tag ‖ payload)
///
/// - `tag` 是 ASCII "UniPass Inkan signer local data" 加一个 0x00。
/// - `payload` 是文件里存的那段 JSON 原样的字节，不重新编码，所以不需要规范化。
///
/// 这个密钥同时是 Safe 的签名人，所以这份签名绝不能被当成有效的 Safe 签名。合约验签时，签名消息是
/// `authenticatorData ‖ sha256(clientDataJSON)`，并要求 `authenticatorData[32] & 0x04`（UV）置位
/// （docs/webauthn-signature.md）。这里的消息固定 65 字节，能对上的拆分只有 `authenticatorData` = 前 33 字节，
/// 它的第 33 个字节恒为 0x00，UV 没有置位，合约必然拒绝；最后 32 字节是以 `tag` 开头的数据的哈希，
/// 不可能等于以 `{"type":"webauthn.get"` 开头的 clientDataJSON 的哈希（除非 SHA-256 碰撞）。
/// 反过来，Safe 签名的消息是 69 字节、以 sha256("unipass.xyz") 开头，也不可能被当成本地数据的签名。
public enum LocalDataSignature {
    public static let tag = Data("UniPass Inkan signer local data".utf8) + Data([0])

    public static func message(for payload: Data) -> Data {
        tag + Data([0]) + Data(SHA256.hash(data: tag + payload))
    }

    public static func isValid(_ signature: Data, payload: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return publicKey.isValidSignature(sig, for: message(for: payload))
    }
}

/// 给本地数据签名的一方。App 用 `faceID(key:policy:reason:)`；测试可以直接传软件密钥。
public struct LocalDataSigner: Sendable {
    public let publicKey: P256.Signing.PublicKey
    let signMessage: @Sendable (Data) async throws -> Data

    public init(publicKey: P256.Signing.PublicKey, sign: @escaping @Sendable (Data) async throws -> Data) {
        self.publicKey = publicKey
        self.signMessage = sign
    }

    /// SE 密钥先按它的访问控制做一次 Face ID，再用同一个 LAContext 签名；调试用的软件密钥不弹 Face ID。
    public static func faceID(key: any P256SigningKey, policy: BiometryPolicy?, reason: String) -> LocalDataSigner {
        LocalDataSigner(publicKey: key.publicKey) { message in
            let context = LAContext()
            if key.kind == .secureEnclave { try await TransactionSigner.authenticate(context, policy, reason) }
            return try key.rawSignature(for: message, context: context)
        }
    }

    func sign(payload: Data) async throws -> Data {
        try await signMessage(LocalDataSignature.message(for: payload))
    }
}
