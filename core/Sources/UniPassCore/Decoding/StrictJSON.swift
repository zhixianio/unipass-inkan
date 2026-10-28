import Foundation

/// 严格的 JSON（RFC 8259）解析，只给 SafeTx 的 EIP-712 JSON 用。
/// 和 Foundation 的 JSONSerialization 不同：对象保持键的顺序、重复键直接拒绝、数字保留原文、
/// 有深度和大小上限、字符串只接受可打印 ASCII（不允许转义）——我们自己的规范格式里用不到别的。
enum StrictJSON: Hashable, Sendable {
    case object([(key: String, value: StrictJSON)])
    case array([StrictJSON])
    case string(String)
    /// 数字原文（已按 JSON 语法校验）。
    case number(String)
    case bool(Bool)
    case null

    static func == (a: StrictJSON, b: StrictJSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let x), .array(let y)): x == y
        case (.string(let x), .string(let y)), (.number(let x), .number(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        default: false
        }
    }

    func hash(into h: inout Hasher) {
        switch self {
        case .object(let o): h.combine(0); for e in o { h.combine(e.key); h.combine(e.value) }
        case .array(let a): h.combine(1); h.combine(a)
        case .string(let s): h.combine(2); h.combine(s)
        case .number(let n): h.combine(3); h.combine(n)
        case .bool(let b): h.combine(4); h.combine(b)
        case .null: h.combine(5)
        }
    }

    struct Limits {
        var maxBytes = 64 * 1024
        var maxDepth = 8
        var maxItems = 4096
    }

    enum Error: Swift.Error, Hashable {
        case tooLarge
        case tooDeep
        case tooManyItems
        case syntax(offset: Int)
        case duplicateKey(String)
        case unsupportedString(offset: Int)
    }

    init(parsing data: Data, limits: Limits = Limits()) throws {
        guard data.count <= limits.maxBytes else { throw Error.tooLarge }
        var p = Parser(bytes: [UInt8](data), limits: limits)
        p.skipWhitespace()
        self = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw Error.syntax(offset: p.i) }
    }

    /// 紧凑序列化（无空白），键按保存的顺序。字符串原样输出（解析时已保证不含需要转义的字符）。
    var serialized: String {
        switch self {
        case .object(let o): "{" + o.map { "\"\($0.key)\":" + $0.value.serialized }.joined(separator: ",") + "}"
        case .array(let a): "[" + a.map(\.serialized).joined(separator: ",") + "]"
        case .string(let s): "\"\(s)\""
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        }
    }

    struct Parser {
        let bytes: [UInt8]
        let limits: Limits
        var i = 0
        var items = 0

        init(bytes: [UInt8], limits: Limits) {
            self.bytes = bytes
            self.limits = limits
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ s: String) throws {
            for c in s.utf8 {
                guard i < bytes.count, bytes[i] == c else { throw Error.syntax(offset: i) }
                i += 1
            }
        }

        mutating func value(depth: Int) throws -> StrictJSON {
            items += 1
            guard items <= limits.maxItems else { throw Error.tooManyItems }
            guard i < bytes.count else { throw Error.syntax(offset: i) }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                guard depth < limits.maxDepth else { throw Error.tooDeep }
                i += 1
                var out: [(key: String, value: StrictJSON)] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                while true {
                    skipWhitespace()
                    let key = try string()
                    if out.contains(where: { $0.key == key }) { throw Error.duplicateKey(key) }
                    skipWhitespace()
                    try expect(":")
                    skipWhitespace()
                    out.append((key, try value(depth: depth + 1)))
                    skipWhitespace()
                    guard i < bytes.count else { throw Error.syntax(offset: i) }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                    throw Error.syntax(offset: i)
                }
            case UInt8(ascii: "["):
                guard depth < limits.maxDepth else { throw Error.tooDeep }
                i += 1
                var out: [StrictJSON] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                while true {
                    skipWhitespace()
                    out.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard i < bytes.count else { throw Error.syntax(offset: i) }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                    throw Error.syntax(offset: i)
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try expect("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null"); return .null
            default:
                return .number(try number())
            }
        }

        /// 只接受可打印 ASCII（0x20–0x7E），不接受反斜杠转义。
        mutating func string() throws -> String {
            try expect("\"")
            let start = i
            while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                guard (0x20...0x7E).contains(bytes[i]), bytes[i] != UInt8(ascii: "\\") else {
                    throw Error.unsupportedString(offset: i)
                }
                i += 1
            }
            guard i < bytes.count else { throw Error.syntax(offset: i) }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            i += 1
            return s
        }

        /// RFC 8259 的数字语法：`-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`。
        mutating func number() throws -> String {
            let start = i
            func digit(_ j: Int) -> Bool { j < bytes.count && (0x30...0x39).contains(bytes[j]) }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digit(i) else { throw Error.syntax(offset: i) }
            if bytes[i] == UInt8(ascii: "0") { i += 1 } else { while digit(i) { i += 1 } }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digit(i) else { throw Error.syntax(offset: i) }
                while digit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digit(i) else { throw Error.syntax(offset: i) }
                while digit(i) { i += 1 }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
    }

    subscript(key: String) -> StrictJSON? {
        if case .object(let o) = self { o.first { $0.key == key }?.value } else { nil }
    }

    var keys: [String]? { if case .object(let o) = self { o.map(\.key) } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var numberValue: String? { if case .number(let n) = self { n } else { nil } }
    var arrayValue: [StrictJSON]? { if case .array(let a) = self { a } else { nil } }
}
