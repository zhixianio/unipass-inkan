import Foundation

/// 256 位无符号整数，只实现编码和校验需要的运算。
/// `words[0]` 是最低 64 位。
public struct UInt256: Hashable, Comparable, Sendable, CustomStringConvertible {
    public private(set) var words: [UInt64]

    public static let zero = UInt256(0)
    public static let max = UInt256(words: [.max, .max, .max, .max])

    public init(_ value: UInt64) {
        words = [value, 0, 0, 0]
    }

    public init(words: [UInt64]) {
        precondition(words.count == 4)
        self.words = words
    }

    /// 大端字节，最多 32 字节。
    public init?(bigEndian bytes: Data) {
        guard bytes.count <= 32 else { return nil }
        let padded = Data(repeating: 0, count: 32 - bytes.count) + bytes
        var w = [UInt64](repeating: 0, count: 4)
        for (i, byte) in padded.enumerated() {
            let word = 3 - i / 8
            w[word] = w[word] << 8 | UInt64(byte)
        }
        words = w
    }

    /// 十进制字符串；溢出或含非数字字符时返回 nil。
    public init?(decimal: String) {
        guard !decimal.isEmpty else { return nil }
        var result = UInt256.zero
        for c in decimal.utf8 {
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
            guard let next = result.multipliedAdding(10, UInt64(c - UInt8(ascii: "0"))) else { return nil }
            result = next
        }
        self = result
    }

    /// 十六进制字符串，允许 `0x` 前缀和奇数位。
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        guard !s.isEmpty, s.count <= 64 else { return nil }
        guard let data = Data(hex: s.count % 2 == 0 ? String(s) : "0" + s) else { return nil }
        self.init(bigEndian: data)
    }

    /// 32 字节大端编码（即 ABI 的 uint256 编码）。
    public var bigEndianBytes: Data {
        var out = Data(capacity: 32)
        for word in words.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return out
    }

    public var isZero: Bool { words.allSatisfy { $0 == 0 } }

    public var description: String {
        if isZero { return "0" }
        var digits = [Character]()
        var n = self
        while !n.isZero {
            let (q, r) = n.dividedBy(10)
            digits.append(Character(String(r)))
            n = q
        }
        return String(digits.reversed())
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in (0..<4).reversed() where lhs.words[i] != rhs.words[i] {
            return lhs.words[i] < rhs.words[i]
        }
        return false
    }

    /// 带借位的减法；`lhs < rhs` 时返回 nil。
    public func subtracting(_ rhs: UInt256) -> UInt256? {
        guard self >= rhs else { return nil }
        var out = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = words[i].subtractingReportingOverflow(rhs.words[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 || o2) ? 1 : 0
        }
        return UInt256(words: out)
    }

    /// `self * m + a`，溢出时返回 nil。
    func multipliedAdding(_ m: UInt64, _ a: UInt64) -> UInt256? {
        var out = [UInt64](repeating: 0, count: 4)
        var carry = a
        for i in 0..<4 {
            let (hi, lo) = words[i].multipliedFullWidth(by: m)
            let (sum, o) = lo.addingReportingOverflow(carry)
            out[i] = sum
            carry = hi + (o ? 1 : 0)
        }
        return carry == 0 ? UInt256(words: out) : nil
    }

    func dividedBy(_ d: UInt64) -> (quotient: UInt256, remainder: UInt64) {
        var out = [UInt64](repeating: 0, count: 4)
        var rem: UInt64 = 0
        for i in (0..<4).reversed() {
            (out[i], rem) = d.dividingFullWidth((rem, words[i]))
        }
        return (UInt256(words: out), rem)
    }
}
