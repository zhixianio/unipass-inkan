import Foundation

public enum URError: Error, Hashable, Sendable {
    case invalidScheme
    case invalidType
    case invalidPathLength
    case invalidSequenceComponent
    case bytewords(Bytewords.DecodingError)
    case invalidCBOR(CBORError)
    case invalidPart
    /// 帧字符串里的 seqNum-seqLen 和帧 CBOR 里的不一致。
    case sequenceMismatch
    /// 多帧解码器收到了别的类型的 UR。
    case typeMismatch
    /// 期待单帧却收到多帧，或反过来。
    case unexpectedPartCount
    case messageTooLarge
    case tooManyFragments
    case tooManyParts
    /// 暂存的混合帧超过上限（`FountainDecoder.Limits.maxMixedParts`）。
    case decoderStateTooLarge
    case invalidChecksum
}

/// Uniform Resource（BCR-2020-005）：类型名 + 顶层不带 tag 的 CBOR。
public struct UR: Hashable, Sendable {
    public let type: String
    /// 顶层 CBOR 的确定性编码。
    public let cbor: Data

    /// 类型名只能是 `[a-z0-9-]`，非空。
    public static func isValidType(_ type: String) -> Bool {
        !type.isEmpty && type.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    public init(type: String, value: CBOR) throws {
        guard Self.isValidType(type) else { throw URError.invalidType }
        self.type = type
        cbor = value.encoded()
    }

    /// `cbor` 必须能被严格解码（见 `CBORDecodingOptions`）。
    public init(type: String, cbor: Data, options: CBORDecodingOptions = .strict) throws {
        guard Self.isValidType(type) else { throw URError.invalidType }
        do { _ = try CBOR(decoding: cbor, options: options) } catch let e as CBORError { throw URError.invalidCBOR(e) }
        self.type = type
        self.cbor = cbor
    }

    public var value: CBOR { try! CBOR(decoding: cbor, options: .lenientForValidated) }

    /// 单帧字符串，小写。
    public var string: String { "ur:\(type)/" + Bytewords.encode(cbor) }

    /// 放进二维码用的大写形式（只用 QR 字母数字字符集，码更小）。
    public var qrString: String { string.uppercased() }

    /// 解析单帧 UR。多帧的帧字符串请用 `URDecoder`。
    public init(parsing string: String, options: CBORDecodingOptions = .strict) throws {
        let parsed = try URParser.parse(string)
        guard parsed.components.count == 1 else { throw URError.unexpectedPartCount }
        let body: Data
        do { body = try Bytewords.decode(parsed.components[0]) } catch let e as Bytewords.DecodingError {
            throw URError.bytewords(e)
        }
        try self.init(type: parsed.type, cbor: body, options: options)
    }
}

extension CBORDecodingOptions {
    /// 只用于重新解码已经严格校验过的数据，限制放到最宽避免二次检查失败。
    static let lenientForValidated: CBORDecodingOptions = {
        var o = CBORDecodingOptions()
        o.maxInputSize = .max
        o.maxDepth = .max
        o.maxItems = .max
        o.requireShortestEncoding = false
        o.requireSortedMapKeys = false
        o.requireNFCText = false
        return o
    }()
}

enum URParser {
    /// 和参考实现相比更严：不允许空路径段（`ur:a//b`）、seq 只能是不带前导零的十进制数字。
    static func parse(_ string: String) throws -> (type: String, components: [String]) {
        let lowered = string.lowercased()
        guard lowered.hasPrefix("ur:") else { throw URError.invalidScheme }
        let components = lowered.dropFirst(3).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2 || components.count == 3, components.allSatisfy({ !$0.isEmpty }) else {
            throw URError.invalidPathLength
        }
        guard UR.isValidType(components[0]) else { throw URError.invalidType }
        return (components[0], Array(components.dropFirst()))
    }

    static func parseSequence(_ s: String) throws -> (seqNum: UInt32, seqLen: Int) {
        let pieces = s.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let n = parseDecimal(pieces[0]), n >= 1, n <= UInt32.max,
              let len = parseDecimal(pieces[1]), len >= 1, len <= UInt64(Int32.max)
        else { throw URError.invalidSequenceComponent }
        return (UInt32(n), Int(len))
    }

    private static func parseDecimal(_ s: Substring) -> UInt64? {
        guard !s.isEmpty, s.count <= 10, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              s == "0" || !s.hasPrefix("0") else { return nil }
        return UInt64(s)
    }
}

/// 把一个 UR 编成一串帧。消息放得进一片时只产生单帧形式（规范要求）。
public struct UREncoder: Sendable {
    public let ur: UR
    var fountain: FountainEncoder

    public init(_ ur: UR, maxFragmentLen: Int, minFragmentLen: Int = 10, firstSeqNum: UInt32 = 0) {
        self.ur = ur
        fountain = FountainEncoder(message: ur.cbor, maxFragmentLen: maxFragmentLen,
                                   minFragmentLen: minFragmentLen, firstSeqNum: firstSeqNum)
    }

    public var isSinglePart: Bool { fountain.seqLen == 1 }
    public var seqLen: Int { fountain.seqLen }
    /// 已经发出过每个原始分片。
    public var isComplete: Bool { fountain.isComplete }

    public mutating func nextPart() -> String {
        if isSinglePart { return ur.string }
        let part = fountain.nextPart()
        return "ur:\(ur.type)/\(part.seqNum)-\(part.seqLen)/" + Bytewords.encode(part.cbor.encoded())
    }
}

/// 扫码时逐帧喂入。单帧 UR 直接完成；多帧按喷泉码累积。
public struct URDecoder: Sendable {
    public private(set) var expectedType: String?
    var fountain: FountainDecoder
    let cborOptions: CBORDecodingOptions
    public private(set) var result: Result<UR, URError>?

    public init(limits: FountainDecoder.Limits = .init(), cborOptions: CBORDecodingOptions = .strict) {
        fountain = FountainDecoder(limits: limits)
        self.cborOptions = cborOptions
    }

    /// 0...1，只给界面用。
    public var progress: Double {
        if result != nil { return 1 }
        guard let n = fountain.expectedFragmentCount else { return 0 }
        return Double(fountain.receivedFragmentCount) / Double(n)
    }

    /// 单帧的格式错误（bytewords、CBOR、头部）抛错但不影响已累积的状态，可以继续扫；
    /// 校验和错、超限这类致命错误会把解码器置为失败。
    @discardableResult
    public mutating func receive(_ string: String) throws -> FountainDecoder.Outcome {
        if case .failure(let e)? = result { throw e }
        guard result == nil else { return .ignored }
        let parsed = try URParser.parse(string)
        if let expectedType, parsed.type != expectedType { return .ignored }

        if parsed.components.count == 1 {
            // 已经开始收多帧时，不接受混进来的单帧。
            guard fountain.expectedFragmentCount == nil else { throw URError.unexpectedPartCount }
            let ur = try UR(parsing: string, options: cborOptions)
            result = .success(ur)
            return .accepted
        }

        let seq = try URParser.parseSequence(parsed.components[0])
        let body: Data
        do { body = try Bytewords.decode(parsed.components[1]) } catch let e as Bytewords.DecodingError {
            throw URError.bytewords(e)
        }
        let partCBOR: CBOR
        do { partCBOR = try CBOR(decoding: body) } catch let e as CBORError { throw URError.invalidCBOR(e) }
        let part = try FountainPart(cbor: partCBOR)
        guard part.seqNum == seq.seqNum, part.seqLen == seq.seqLen else { throw URError.sequenceMismatch }

        let outcome: FountainDecoder.Outcome
        do { outcome = try fountain.receive(part) } catch let e as URError {
            result = .failure(e)
            throw e
        }
        if outcome == .accepted, expectedType == nil { expectedType = parsed.type }
        if case .success(let message)? = fountain.result {
            do {
                result = .success(try UR(type: parsed.type, cbor: message, options: cborOptions))
            } catch let e as URError {
                result = .failure(e)
                throw e
            }
        }
        return outcome
    }
}
