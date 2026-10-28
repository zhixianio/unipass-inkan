import Foundation
import Security
import UniPassCore

/// 发给自己 Signer 的一次签名请求（docs/ur-types.md「发给我们自己 Signer 的请求」）：
/// 标准 `eth-sign-request`，data-type 2，sign-data 是 `SafeTxRequest.canonicalJSON`，
/// derivation-path `{1: [], 2: 密钥指纹}`，address 是这台 Signer 的 proxy。
///
/// 桌面端不知道 Signer 有没有登记过这个 Safe，所以二维码一律发 `unipass-sign-request`：
/// 把 `eth-sign-request` 和这个 Safe 的 `unipass-safe` 包在一起，Signer 第一次见到时顺带登记。
public struct SignRequestSession: Hashable, Sendable {
    public static let origin = "UniPass Inkan Desktop"

    public let request: SafeTxRequest
    public let signer: PairedSigner
    public let signRequest: EthSignRequest
    /// 这个 Safe 的创建参数；和 `request` 必须是同一个 Safe（同一条链、同一个地址）。
    public let registration: SafeRegistration

    public init(request: SafeTxRequest, signer: PairedSigner, registration: SafeRegistration,
                requestID: Data = Self.randomRequestID()) {
        precondition(requestID.count == 16)
        precondition(registration.chainID == request.chainID && registration.safe == request.safe,
                     "登记信息必须是请求签的这个 Safe")
        self.request = request
        self.signer = signer
        self.registration = registration
        signRequest = EthSignRequest(
            requestID: requestID,
            signData: Data(request.canonicalJSON.utf8),
            dataType: .typedData,
            chainID: request.chainID,
            derivationPath: signer.pairing.requestKeypath,
            address: signer.signerProxy,
            origin: Self.origin
        )
    }

    public var requestID: Data { signRequest.requestID! }
    /// 本机用 core 重算的 safeTxHash；收回签名时用它做 challenge，不信任任何回传值。
    public var safeTxHash: Data { request.safeTxHash }
    public var shortHash: String { HashDisplay.short(safeTxHash) }
    /// 二维码里发的：`unipass-sign-request`（签名请求 + 登记信息）。
    public var ur: UR { SignRequestWithSafe(request: signRequest, registration: registration).ur }

    public static func randomRequestID() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        // UUID v4 的版本和变体位（tag 37 是 UUID）。
        bytes[6] = bytes[6] & 0x0F | 0x40
        bytes[8] = bytes[8] & 0x3F | 0x80
        return Data(bytes)
    }
}

public enum HashDisplay {
    /// 交易指纹（safeTxHash 短码）：前 8 位 + 后 8 位，按 4 位分组，和 Signer 确认页的写法逐字一致
    /// （apps/signer/Signer/Components.swift `Display.shortHash`）。只是显示，不要求用户比对。
    public static func short(_ h: Data) -> String {
        let hex = Array(h.hexString.dropFirst(2))
        guard hex.count >= 16 else { return String(hex) }
        let head = String(hex[0..<4]) + " " + String(hex[4..<8])
        let tail = String(hex[(hex.count - 8)..<(hex.count - 4)]) + " " + String(hex[(hex.count - 4)...])
        return head + " … " + tail
    }
}
