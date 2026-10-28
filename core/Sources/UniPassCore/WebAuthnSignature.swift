import CryptoKit
import Foundation

/// Signer 手工拼出的 WebAuthn 断言，交给 safe-modules 的 `SafeWebAuthnSignerProxy` 验签。
/// 格式见 docs/webauthn-signature.md（草案，M0 验证中）。
public struct WebAuthnAssertion: Hashable, Sendable {
    public var authenticatorData: Data
    public var clientDataFields: String

    public init(authenticatorData: Data, clientDataFields: String) {
        self.authenticatorData = authenticatorData
        self.clientDataFields = clientDataFields
    }

    /// 写进 Signer 断言 rpIdHash 的 RP ID。合约不校验它，取产品域名只为可辨认。
    public static let signerRPID = "unipass.xyz"

    /// Signer 的默认取值。
    public static let signerDefault = WebAuthnAssertion(
        authenticatorData: Data(SHA256.hash(data: Data(signerRPID.utf8)))
            + Data([0x05]) // UP | UV
            + Data([0, 0, 0, 0]), // signCount
        clientDataFields: #""origin":"unipass-signer://secure-enclave","crossOrigin":false"#
    )

    /// 合约重建出的 clientDataJSON。
    public func clientDataJSON(challenge: Data) -> Data {
        Data(#"{"type":"webauthn.get","challenge":""#.utf8)
            + Data(Base64URL.encode(challenge).utf8)
            + Data(#"","#.utf8)
            + Data(clientDataFields.utf8)
            + Data("}".utf8)
    }

    /// 交给 P-256 签名的消息（签名时会再做一次 SHA-256）。
    public func signingMessage(challenge: Data) -> Data {
        authenticatorData + Data(SHA256.hash(data: clientDataJSON(challenge: challenge)))
    }

    /// proxy 接受的签名：`abi.encode(bytes authenticatorData, string clientDataFields, uint256 r, uint256 s)`。
    public func abiEncoded(signature: P256Signature) -> Data {
        let fields = Data(clientDataFields.utf8)
        let authTail = ABI.encodeDynamic(authenticatorData)
        let headSize = 4 * 32
        var out = UInt256(UInt64(headSize)).bigEndianBytes
        out += UInt256(UInt64(headSize + authTail.count)).bigEndianBytes
        out += signature.r.bigEndianBytes
        out += signature.s.bigEndianBytes
        out += authTail
        out += ABI.encodeDynamic(fields)
        return out
    }
}

/// P-256 ECDSA 签名的 r、s。
public struct P256Signature: Hashable, Sendable {
    public var r: UInt256
    public var s: UInt256

    /// P-256 曲线的阶 n。
    public static let curveOrder = UInt256(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!
    static let halfOrder = UInt256(hex: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")!

    public init(r: UInt256, s: UInt256) {
        self.r = r
        self.s = s
    }

    /// 64 字节 r‖s（CryptoKit 的 `rawRepresentation`）。
    public init?(raw: Data) {
        guard raw.count == 64,
              let r = UInt256(bigEndian: raw.prefix(32)),
              let s = UInt256(bigEndian: raw.suffix(32))
        else { return nil }
        self.init(r: r, s: s)
    }

    public var isLowS: Bool { s <= Self.halfOrder }

    /// `s > n/2` 时换成 `n − s`，两者对同一消息都有效。
    public var normalizedToLowS: P256Signature {
        isLowS ? self : P256Signature(r: r, s: Self.curveOrder.subtracting(s)!)
    }
}

enum ABI {
    /// 动态类型（bytes / string）的尾部：长度 + 右侧补零到 32 字节整数倍。
    static func encodeDynamic(_ data: Data) -> Data {
        let padding = (32 - data.count % 32) % 32
        return UInt256(UInt64(data.count)).bigEndianBytes + data + Data(repeating: 0, count: padding)
    }
}

enum Base64URL {
    /// 无填充的 base64url。
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
