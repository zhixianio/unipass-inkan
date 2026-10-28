import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UniPassCore

public enum SigningKeyKind: UInt8, Sendable {
    case secureEnclave = 1
    /// 只在模拟器 / DEBUG 构建里存在，界面上必须明确标出。
    case softwareDebug = 2
}

/// Safe owner 用的 P-256 密钥。
public protocol P256SigningKey: Sendable {
    var kind: SigningKeyKind { get }
    var publicKey: P256.Signing.PublicKey { get }
    /// 对 `message` 做 SHA-256 后签名，返回 64 字节 r‖s（未做 low-s）。
    /// `context` 是已经通过 Face ID 的 LAContext 时不会再弹；为 nil 时 SE 密钥会在这里弹 Face ID。
    /// 会阻塞，不要在主线程调。
    func rawSignature(for message: Data, context: LAContext?) throws -> Data
}

extension P256SigningKey {
    public func rawSignature(for message: Data) throws -> Data { try rawSignature(for: message, context: nil) }
}

extension P256SigningKey {
    /// 公钥坐标 x、y，各 32 字节大端。
    public var publicKeyXY: (x: Data, y: Data) {
        let raw = publicKey.rawRepresentation
        return (raw.prefix(32), raw.suffix(32))
    }
}

/// SE 密钥签名时认哪些面容。用户在生成密钥时选，选完不能改（只能换新密钥）。
/// 真机实测（apps/signer/README.md）：加"备用外貌"后 `.anyEnrolled` 照常签名，
/// `.currentSet` 永久失效（CryptoTokenKit -3 "unable to sign digest"）。
public enum BiometryPolicy: UInt8, Sendable, CaseIterable, Identifiable {
    /// `.biometryAny`：任何已录入的面容都能签；Face ID 录入变化后仍可用。
    case anyEnrolled = 1
    /// `.biometryCurrentSet`：只认生成时已录入的面容；录入一变密钥永久失效。
    case currentSet = 2

    public var id: Self { self }

    /// 配对数据等对外格式里的名字。
    public var name: String {
        switch self {
        case .anyEnrolled: "anyEnrolled"
        case .currentSet: "currentSet"
        }
    }

    public init?(name: String) {
        guard let p = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = p
    }

    public var flags: SecAccessControlCreateFlags {
        switch self {
        case .anyEnrolled: .biometryAny
        case .currentSet: .biometryCurrentSet
        }
    }

    /// 只在设置了锁屏密码时可用、不随备份迁移，签名需要生物识别（没有密码后备）。
    public func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, flags],
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return ac
    }
}

extension BiometryPolicy {
    /// SE 签名的错误是不是"Face ID 录入变了、`.currentSet` 密钥已失效"。
    /// 真机上是 CryptoTokenKit -3 "unable to sign digest"，错误本身不说原因，所以只对 `.currentSet` 这样解释。
    public func explainsInvalidation(_ error: Error) -> Bool {
        let e = error as NSError
        return self == .currentSet && e.domain == "CryptoTokenKit" && e.code == -3
    }
}

public struct SecureEnclaveSigningKey: P256SigningKey {
    public let kind = SigningKeyKind.secureEnclave
    /// SE 加密过的密钥句柄，只有这台设备的 SE 能用；存进 Keychain。
    public let dataRepresentation: Data
    public let publicKey: P256.Signing.PublicKey

    /// iOS 26.5 模拟器（Apple 芯片 Mac）上 `SecureEnclave.isAvailable` 返回 true，但带生物识别
    /// 访问控制创建密钥会失败（LAError -1020 "not supported on iOS Simulator"），所以模拟器一律算没有。
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }

    public static func generate(policy: BiometryPolicy) throws -> SecureEnclaveSigningKey {
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: policy.accessControl())
        return SecureEnclaveSigningKey(dataRepresentation: key.dataRepresentation, publicKey: key.publicKey)
    }

    public init(dataRepresentation: Data) throws {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
        self.init(dataRepresentation: dataRepresentation, publicKey: key.publicKey)
    }

    private init(dataRepresentation: Data, publicKey: P256.Signing.PublicKey) {
        self.dataRepresentation = dataRepresentation
        self.publicKey = publicKey
    }

    public func rawSignature(for message: Data, context: LAContext?) throws -> Data {
        let context = context ?? {
            let c = LAContext()
            c.localizedReason = String(localized: "Sign with Face ID")
            return c
        }()
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: dataRepresentation,
            authenticationContext: context
        )
        return try key.signature(for: message).rawRepresentation
    }
}

#if targetEnvironment(simulator) || DEBUG
/// 模拟器没有 SE 时的软件密钥后备。私钥明文在内存和 Keychain 里，**只用于开发**。
/// Release 真机构建里这个类型不存在。
public struct SoftwareDebugSigningKey: P256SigningKey {
    public let kind = SigningKeyKind.softwareDebug
    public let privateKey: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public var publicKey: P256.Signing.PublicKey { privateKey.publicKey }

    public func rawSignature(for message: Data, context: LAContext?) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}
#endif

/// 一次签名的结果。
public struct SignedAssertion: Sendable {
    public var challenge: Data
    public var assertion: WebAuthnAssertion
    /// low-s 规范化后的签名。
    public var signature: P256Signature
    /// 规范化前 s 是否为 high-s（调试用）。
    public var wasHighS: Bool
    /// 交给 `SafeWebAuthnSignerProxy` 的签名（ABI 编码）。
    public var proxySignature: Data { assertion.abiEncoded(signature: signature) }
}

public enum WebAuthnSigner {
    public enum Failure: Error {
        case challengeNot32Bytes
        case malformedSignature
    }

    /// 按 docs/webauthn-signature.md 拼 authenticatorData / clientDataJSON、签名、做 low-s。
    public static func sign(
        challenge: Data,
        with key: some P256SigningKey,
        assertion: WebAuthnAssertion = .signerDefault,
        context: LAContext? = nil
    ) throws -> SignedAssertion {
        guard challenge.count == 32 else { throw Failure.challengeNot32Bytes }
        let raw = try key.rawSignature(for: assertion.signingMessage(challenge: challenge), context: context)
        guard let sig = P256Signature(raw: raw) else { throw Failure.malformedSignature }
        return SignedAssertion(
            challenge: challenge,
            assertion: assertion,
            signature: sig.normalizedToLowS,
            wasHighS: !sig.isLowS
        )
    }

    /// 用公钥本地复验（CryptoKit 同时接受 low-s 和 high-s）。
    public static func verify(_ signed: SignedAssertion, publicKey: P256.Signing.PublicKey) -> Bool {
        let raw = signed.signature.r.bigEndianBytes + signed.signature.s.bigEndianBytes
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return publicKey.isValidSignature(sig, for: signed.assertion.signingMessage(challenge: signed.challenge))
    }
}
