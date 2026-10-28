import Foundation
import LocalAuthentication
import UniPassCore

/// 签一笔交易。只接受 `SignableTransaction`（只能从没被拒的 RiskAssessment 构造），
/// challenge 取它里面重算出的 safeTxHash。顺序：
/// 1. Face ID（SE 密钥时）；
/// 2. **再查一次联网**——用户可能在确认页停留期间打开了 Wi-Fi；
/// 3. 用第 1 步通过认证的 LAContext 调 SE 签名（不会再弹第二次）。
public enum TransactionSigner {
    public enum Failure: Error, Equatable {
        /// Face ID 通过后发现联网了。
        case networkOnline
        /// 还没有签名密钥。
        case noKey
        case authenticationFailed(String)
    }

    public typealias Authenticate = @Sendable (LAContext, BiometryPolicy?) async throws -> Void

    /// 默认的认证：按密钥的访问控制做一次 Face ID。`reason` 是系统弹窗里的说明，由 App 本地化后传入。
    public static func faceID(reason: String) -> Authenticate {
        { context, policy in
            try await authenticate(context, policy, reason)
        }
    }

    static func authenticate(_ context: LAContext, _ policy: BiometryPolicy?, _ reason: String) async throws {
        if let policy {
            _ = try await context.evaluateAccessControl(try policy.accessControl(), operation: .useKeySign, localizedReason: reason)
        } else {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        }
    }

    public static func sign(
        _ tx: SignableTransaction,
        with key: any P256SigningKey,
        policy: BiometryPolicy?,
        isOffline: @Sendable () -> Bool,
        authenticate: Authenticate
    ) async throws -> SignerSignature {
        let context = LAContext()
        if key.kind == .secureEnclave {
            do { try await authenticate(context, policy) } catch {
                throw Failure.authenticationFailed("\(error)")
            }
        }
        guard isOffline() else { throw Failure.networkOnline }
        let signed = try WebAuthnSigner.sign(challenge: tx.challenge, with: key, context: context)
        return SignerSignature(requestID: tx.requestID, assertion: signed.assertion, signature: signed.signature)
    }
}
