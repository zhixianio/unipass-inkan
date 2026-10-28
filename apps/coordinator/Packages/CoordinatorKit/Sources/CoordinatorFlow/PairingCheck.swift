import Foundation
import UniPassCore

/// 扫到的配对码能不能保存。按顺序：factory 和 verifiers 必须是规范值（先查，不用联网）；链上 `getSigner`
/// 必须核对成、而且和配对码里的 proxy 一致；已经配对过的 proxy 不能换公钥。
///
/// 不是规范 factory 时，攻击者自己的合约可以让 `getSigner` 返回任意地址，链上核对就没有意义了。
public enum PairingCheck: Hashable, Sendable {
    case ok
    /// factory 或 verifiers 不是规范值。
    case notCanonical
    /// 链上没核对成（网络、节点）。不保存，让用户再扫一次。
    case unverified
    /// 链上 `getSigner` 算出的地址和配对码里的不一样。
    case mismatch(onChain: Address)
    /// 这个 proxy 已经配对过，公钥却不一样。
    case keyChanged

    /// safe-modules 的 SafeWebAuthnSignerFactory（签名器 `SignerProxy.factory`）。
    public static let signerFactory = SafeCreation.signerFactory
    /// P256.Verifiers：0x0100 预编译 + FCL 回退验证合约（签名器 `SignerProxy.defaultVerifiers`）。
    public static let canonicalVerifiers = Data(hex: "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")!

    /// 联网之前就能查的部分。
    public static func isCanonical(_ p: SignerPairing) -> Bool {
        p.signerFactory == signerFactory && p.verifiers == canonicalVerifiers
    }

    /// `onChain`：用当前 Safe 所在链的节点调 `getSigner` 的结果；没核对成时为 nil。
    public static func check(_ p: SignerPairing, onChain: Address?, paired: PairedSigners) -> PairingCheck {
        guard isCanonical(p) else { return .notCanonical }
        guard let onChain else { return .unverified }
        guard onChain == p.signerProxy else { return .mismatch(onChain: onChain) }
        if let known = paired.signer(p.signerProxy), !known.hasSameKey(as: p) { return .keyChanged }
        return .ok
    }
}

extension PairedSigner {
    func hasSameKey(as p: SignerPairing) -> Bool {
        x == p.x && y == p.y && verifiers == p.verifiers && signerFactory == p.signerFactory
    }
}
