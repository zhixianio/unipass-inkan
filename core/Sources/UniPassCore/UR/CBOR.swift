import Foundation

/// CBOR（RFC 8949）数据项。只覆盖 UR / EIP-4527 / 自定义 UR 类型用得到的部分：
/// 整数、字节串、文本、数组、映射、tag、false / true / null。浮点数和其它 simple 值不支持。
///
/// 编码永远是确定性的（RFC 8949 §4.2.1 Core Deterministic Encoding）：整数和长度用最短形式、
/// 只用定长、映射的键按编码后字节的字典序排列。解码默认同样从严，见 `CBORDecodingOptions`。
public indirect enum CBOR: Hashable, Sendable {
    case unsigned(UInt64)
    /// 值为 `-1 - n`。
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map(CBORMap)
    case tagged(UInt64, CBOR)
    case bool(Bool)
    case null

    public init(_ value: Int) {
        self = value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-(value + 1)))
    }
}

/// 映射：条目按"键的确定性编码"的字节字典序保存，键不重复。
public struct CBORMap: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let key: CBOR
        public let value: CBOR
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// 键重复时抛 `CBORError.duplicateMapKey`。
    public init(_ pairs: [(CBOR, CBOR)]) throws {
        for (k, v) in pairs { try insert(k, v) }
    }

    public mutating func insert(_ key: CBOR, _ value: CBOR) throws {
        let encodedKey = key.encoded()
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let c = CBOR.compareEncoded(entries[mid].key.encoded(), encodedKey)
            if c == 0 { throw CBORError.duplicateMapKey }
            if c < 0 { lo = mid + 1 } else { hi = mid }
        }
        entries.insert(Entry(key: key, value: value), at: lo)
    }

    public subscript(key: CBOR) -> CBOR? {
        entries.first { $0.key == key }?.value
    }

    public subscript(key: Int) -> CBOR? { self[CBOR(key)] }

    public var count: Int { entries.count }
}

public enum CBORError: Error, Hashable, Sendable {
    case truncated
    case trailingBytes
    case inputTooLarge
    case depthExceeded
    case tooManyElements
    /// 附加信息 28–30（保留）。
    case reservedAdditionalInfo
    /// 不定长（附加信息 31）或 break。
    case indefiniteLength
    case nonShortestEncoding
    case unsortedMapKeys
    case duplicateMapKey
    case invalidUTF8
    /// 文本不是 Unicode NFC（dCBOR 要求）。
    case textNotNFC
    case floatNotSupported
    case unsupportedSimpleValue(UInt8)
}

/// 解码限制和从严程度。默认值就是从严的；放宽哪一项都要在调用处写明原因。
public struct CBORDecodingOptions: Sendable {
    /// 整个输入的最大字节数。
    public var maxInputSize = 64 * 1024
    /// 最大嵌套深度（数组、映射、tag 各算一层）。
    public var maxDepth = 32
    /// 全部数据项的总数上限（防止大量小元素耗尽内存）。
    public var maxItems = 16 * 1024
    /// 整数、长度、tag 必须用最短形式。
    public var requireShortestEncoding = true
    /// 映射键必须按确定性编码的字节序排列。
    public var requireSortedMapKeys = true
    /// 文本必须是 NFC。
    public var requireNFCText = true

    public init() {}

    public static let strict = CBORDecodingOptions()
}

// MARK: - 编码

extension CBOR {
    public func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    func encode(into out: inout Data) {
        switch self {
        case .unsigned(let n): Self.writeHead(0, n, &out)
        case .negative(let n): Self.writeHead(1, n, &out)
        case .bytes(let d):
            Self.writeHead(2, UInt64(d.count), &out)
            out += d
        case .text(let s):
            let utf8 = Data(s.utf8)
            Self.writeHead(3, UInt64(utf8.count), &out)
            out += utf8
        case .array(let items):
            Self.writeHead(4, UInt64(items.count), &out)
            for item in items { item.encode(into: &out) }
        case .map(let m):
            Self.writeHead(5, UInt64(m.count), &out)
            for e in m.entries {
                e.key.encode(into: &out)
                e.value.encode(into: &out)
            }
        case .tagged(let tag, let item):
            Self.writeHead(6, tag, &out)
            item.encode(into: &out)
        case .bool(let b): out.append(b ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        }
    }

    /// 最短形式的头部。
    static func writeHead(_ major: UInt8, _ value: UInt64, _ out: inout Data) {
        let m = major << 5
        switch value {
        case 0..<24:
            out.append(m | UInt8(value))
        case 24...0xFF:
            out.append(m | 24)
            out.append(UInt8(value))
        case 0x100...0xFFFF:
            out.append(m | 25)
            withUnsafeBytes(of: UInt16(value).bigEndian) { out += $0 }
        case 0x1_0000...0xFFFF_FFFF:
            out.append(m | 26)
            withUnsafeBytes(of: UInt32(value).bigEndian) { out += $0 }
        default:
            out.append(m | 27)
            withUnsafeBytes(of: value.bigEndian) { out += $0 }
        }
    }

    /// 字节字典序（RFC 8949 §4.2.1：先比第一个不同的字节，短的在前）。
    static func compareEncoded(_ a: Data, _ b: Data) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }
}

// MARK: - 解码

extension CBOR {
    /// 解码恰好一个数据项；后面多出字节算错。
    public init(decoding data: Data, options: CBORDecodingOptions = .strict) throws {
        guard data.count <= options.maxInputSize else { throw CBORError.inputTooLarge }
        var reader = CBORReader(bytes: [UInt8](data), options: options)
        self = try reader.readItem(depth: 0)
        guard reader.position == reader.bytes.count else { throw CBORError.trailingBytes }
    }
}

struct CBORReader {
    let bytes: [UInt8]
    let options: CBORDecodingOptions
    var position = 0
    var items = 0

    init(bytes: [UInt8], options: CBORDecodingOptions) {
        self.bytes = bytes
        self.options = options
    }

    var remaining: Int { bytes.count - position }

    mutating func readByte() throws -> UInt8 {
        guard position < bytes.count else { throw CBORError.truncated }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func readBytes(_ n: UInt64) throws -> ArraySlice<UInt8> {
        guard n <= UInt64(remaining) else { throw CBORError.truncated }
        let start = position
        position += Int(n)
        return bytes[start..<position]
    }

    /// 读头部，返回主类型和参数。
    mutating func readHead() throws -> (major: UInt8, value: UInt64, info: UInt8) {
        let initial = try readByte()
        let major = initial >> 5
        let info = initial & 0x1F
        let value: UInt64
        switch info {
        case 0..<24:
            value = UInt64(info)
        case 24:
            value = UInt64(try readByte())
            if options.requireShortestEncoding, major != 7, value < 24 { throw CBORError.nonShortestEncoding }
        case 25, 26, 27:
            let n = 1 << (info - 24)
            var v: UInt64 = 0
            for b in try readBytes(UInt64(n)) { v = v << 8 | UInt64(b) }
            value = v
            if options.requireShortestEncoding, major != 7 {
                let min: UInt64 = n == 2 ? 0x100 : n == 4 ? 0x1_0000 : 0x1_0000_0000
                if value < min { throw CBORError.nonShortestEncoding }
            }
        case 28, 29, 30:
            throw CBORError.reservedAdditionalInfo
        default:
            throw CBORError.indefiniteLength
        }
        return (major, value, info)
    }

    mutating func readItem(depth: Int) throws -> CBOR {
        items += 1
        guard items <= options.maxItems else { throw CBORError.tooManyElements }
        let (major, value, info) = try readHead()
        switch major {
        case 0:
            return .unsigned(value)
        case 1:
            return .negative(value)
        case 2:
            return .bytes(Data(try readBytes(value)))
        case 3:
            guard let s = String(validating: try readBytes(value), as: UTF8.self) else { throw CBORError.invalidUTF8 }
            // Swift 的 String == 按规范等价比较，NFC 检查必须比 UTF-8 字节。
            if options.requireNFCText, !s.precomposedStringWithCanonicalMapping.utf8.elementsEqual(s.utf8) {
                throw CBORError.textNotNFC
            }
            return .text(s)
        case 4:
            guard depth < options.maxDepth else { throw CBORError.depthExceeded }
            // 每个元素至少 1 字节：先挡住超大的声明长度，再分配。
            guard value <= UInt64(options.maxItems) else { throw CBORError.tooManyElements }
            guard value <= UInt64(remaining) else { throw CBORError.truncated }
            var out: [CBOR] = []
            out.reserveCapacity(Int(value))
            for _ in 0..<value { out.append(try readItem(depth: depth + 1)) }
            return .array(out)
        case 5:
            guard depth < options.maxDepth else { throw CBORError.depthExceeded }
            guard value <= UInt64(options.maxItems) else { throw CBORError.tooManyElements }
            guard value <= UInt64(remaining / 2) else { throw CBORError.truncated }
            var map = CBORMap()
            var previousKey: Data?
            for _ in 0..<value {
                let keyStart = position
                let key = try readItem(depth: depth + 1)
                let keyBytes = Data(bytes[keyStart..<position])
                if let previousKey {
                    let c = CBOR.compareEncoded(previousKey, keyBytes)
                    if c == 0 { throw CBORError.duplicateMapKey }
                    if c > 0, options.requireSortedMapKeys { throw CBORError.unsortedMapKeys }
                }
                previousKey = keyBytes
                let v = try readItem(depth: depth + 1)
                // insert 按确定性编码重新排序；放宽排序要求时也靠它查重。
                try map.insert(key, v)
            }
            return .map(map)
        case 6:
            guard depth < options.maxDepth else { throw CBORError.depthExceeded }
            return .tagged(value, try readItem(depth: depth + 1))
        default: // 7
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 25, 26, 27: throw CBORError.floatNotSupported
            default: throw CBORError.unsupportedSimpleValue(UInt8(truncatingIfNeeded: value))
            }
        }
    }
}

// MARK: - 取值

extension CBOR {
    public var uint: UInt64? { if case .unsigned(let n) = self { n } else { nil } }
    public var bytesValue: Data? { if case .bytes(let d) = self { d } else { nil } }
    public var textValue: String? { if case .text(let s) = self { s } else { nil } }
    public var arrayValue: [CBOR]? { if case .array(let a) = self { a } else { nil } }
    public var mapValue: CBORMap? { if case .map(let m) = self { m } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    /// tag 匹配时返回里面的数据项。
    public func untagged(_ tag: UInt64) -> CBOR? {
        if case .tagged(tag, let item) = self { item } else { nil }
    }
}
