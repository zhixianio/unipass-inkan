import Foundation
import UniPassCore

/// 扫 Signer 的 `unipass-pairing` 后保存的身份（都是公开数据，不是密钥）。
public struct PairedSigner: Codable, Hashable, Sendable {
    public var x: Data
    public var y: Data
    public var name: String
    /// `SignerBiometryPolicy` 的原始值；调试用软件密钥没有。
    public var biometryPolicyRaw: UInt64?
    public var signerProxyHex: String
    public var verifiers: Data
    public var signerFactoryHex: String
    public var pairedAt: Date
    /// 配对时链上 `getSigner` 核对过 proxy 地址。不一致的配对不会保存。
    public var verifiedOnChain: Bool

    public init(_ p: SignerPairing, pairedAt: Date = .now, verifiedOnChain: Bool = false) {
        x = p.x
        y = p.y
        name = p.name
        biometryPolicyRaw = p.biometryPolicy?.rawValue
        signerProxyHex = p.signerProxy.checksummed
        verifiers = p.verifiers
        signerFactoryHex = p.signerFactory.checksummed
        self.pairedAt = pairedAt
        self.verifiedOnChain = verifiedOnChain
    }

    public var pairing: SignerPairing {
        SignerPairing(x: x, y: y, name: name, biometryPolicy: biometryPolicyRaw.flatMap(SignerBiometryPolicy.init(rawValue:)),
                      signerProxy: signerProxy, verifiers: verifiers, signerFactory: signerFactory)
    }

    public var signerProxy: Address { Address(hex: signerProxyHex)! }
    public var signerFactory: Address { Address(hex: signerFactoryHex)! }
    public var biometryPolicy: SignerBiometryPolicy? { biometryPolicyRaw.flatMap(SignerBiometryPolicy.init(rawValue:)) }

    /// `SHA-256(0x04 ‖ x ‖ y)` 的前 4 字节，也是发给这台 Signer 的请求里的 source-fingerprint。
    public var keyFingerprint: UInt32 { SignerPairing.keyFingerprint(x: x, y: y) }

    /// 例如 `1A2B 3C4D`。
    public var fingerprintText: String {
        let hex = String(format: "%08X", keyFingerprint)
        return hex.prefix(4) + " " + hex.suffix(4)
    }

    /// 地址的显示方式（和 Signer 一致）：EIP-55，去掉 0x，每 4 位一组。
    public static func addressGroups(_ a: Address) -> [String] {
        let hex = Array(a.checksummed.dropFirst(2))
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<min($0 + 4, hex.count)]) }
    }

    public static func groupedAddress(_ a: Address) -> String {
        addressGroups(a).joined(separator: " ")
    }

    /// 高亮的组：前 8 位、后 8 位（首尾 4+4 防不住地址投毒）。
    public static func isHighlightedGroup(_ index: Int, of count: Int) -> Bool {
        index < 2 || index >= count - 2
    }

    /// Face ID 策略的提示。只是提示，不放行或拒绝任何操作。译文在 App 的 String Catalog。
    public var biometryNotice: LocalizedStringResource? {
        switch biometryPolicy {
        case .anyEnrolled:
            nil
        case .currentSet:
            LocalizedStringResource("This signer's key only works with the faces enrolled now. If Face ID enrollment changes (including adding an alternate appearance), the key stops working for good and the other owners have to replace it. Make sure the remaining owners still meet the threshold without this signer.")
        case nil:
            LocalizedStringResource("This signer uses a debug software key without Face ID protection. Use it for testing only.")
        }
    }

    /// 去掉这台 Signer 之后，剩下的 owner 是否仍然够阈值（currentSet 时用来提示余量）。
    public static func hasMarginWithoutThisSigner(owners: Int, threshold: Int) -> Bool {
        owners - 1 >= threshold
    }
}
