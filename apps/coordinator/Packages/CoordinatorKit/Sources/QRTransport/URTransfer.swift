import Foundation
import UniPassCore

/// 要显示的 UR 帧序列。单帧 UR 一直显示同一帧；多帧时按喷泉码无限出帧（先依次出全部原始分片，之后是混合帧）。
public struct URFrames: Sendable {
    /// 实测（iPhone 15 Pro 和 MacBook 摄像头）：每帧约 200 B（QR v11 左右）、8–10 fps 时，
    /// Mac 摄像头扫 iPhone 一帧不漏；反方向 iPhone 摄像头只会更好。
    public static let defaultMaxFragmentLen = 200

    public let ur: UR
    private var encoder: UREncoder

    public init(_ ur: UR, maxFragmentLen: Int = defaultMaxFragmentLen) {
        self.ur = ur
        encoder = UREncoder(ur, maxFragmentLen: maxFragmentLen)
    }

    public var isSinglePart: Bool { encoder.isSinglePart }
    public var seqLen: Int { encoder.seqLen }

    /// 下一帧，已转成二维码用的大写形式（只用 QR 字母数字字符集）。
    public mutating func next() -> String {
        encoder.nextPart().uppercased()
    }
}

/// 扫码端：把识别出的二维码文本逐帧喂给 core 的 `URDecoder`，记录进度和用时。
public struct URTransferTracker: Sendable {
    /// 只接受这些类型；为空表示任何类型都收。
    public let acceptedTypes: Set<String>
    public private(set) var decoder = URDecoder()
    public private(set) var firstFrameAt: TimeInterval?
    public private(set) var completedAt: TimeInterval?
    public private(set) var result: UR?
    /// 被 core 接受的帧（含重复帧）。
    public private(set) var acceptedFrames = 0
    /// 不是 `ur:` 的二维码，或者类型不对的 UR。
    public private(set) var foreign = 0
    public private(set) var lastForeignPayload: String?
    /// 格式坏的帧（bytewords 校验和、CBOR、帧头）：丢弃后继续扫。
    public private(set) var badFrames = 0
    /// 致命错误（拼完 CRC 不对、超限）：要重新开始。
    public private(set) var failure: URError?
    public private(set) var lastError: String?

    public init(acceptedTypes: Set<String> = []) {
        self.acceptedTypes = acceptedTypes
    }

    public var progress: Double { decoder.progress }

    public var transferSeconds: TimeInterval? {
        guard let firstFrameAt, let completedAt else { return nil }
        return completedAt - firstFrameAt
    }

    /// 返回这次调用刚好拼完的 UR。
    @discardableResult
    public mutating func receive(_ payloads: [String], at time: TimeInterval) -> UR? {
        guard result == nil, failure == nil else { return nil }
        for payload in payloads {
            guard let type = Self.urType(of: payload), acceptedTypes.isEmpty || acceptedTypes.contains(type) else {
                foreign += 1
                lastForeignPayload = payload
                continue
            }
            do {
                if try decoder.receive(payload) == .accepted {
                    acceptedFrames += 1
                    if firstFrameAt == nil { firstFrameAt = time }
                }
            } catch let error as URError {
                lastError = String(describing: error)
                if case .failure? = decoder.result {
                    failure = error
                    return nil
                }
                badFrames += 1
                continue
            } catch {
                lastError = String(describing: error)
                badFrames += 1
                continue
            }
            if case .success(let ur)? = decoder.result {
                if firstFrameAt == nil { firstFrameAt = time }
                completedAt = time
                result = ur
                return ur
            }
        }
        return nil
    }

    public mutating func reset() {
        self = URTransferTracker(acceptedTypes: acceptedTypes)
    }

    /// `ur:<type>/…` 里的类型名（不区分大小写）；不是 UR 时返回 nil。
    static func urType(of payload: String) -> String? {
        let lower = payload.lowercased()
        guard lower.hasPrefix("ur:"), let slash = lower.dropFirst(3).firstIndex(of: "/") else { return nil }
        let type = String(lower[lower.index(lower.startIndex, offsetBy: 3)..<slash])
        return UR.isValidType(type) ? type : nil
    }
}
