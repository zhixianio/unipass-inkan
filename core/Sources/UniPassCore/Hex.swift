import Foundation

extension Data {
    /// 解析十六进制字符串，允许 `0x` 前缀；长度为奇数或含非法字符时返回 nil。
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var it = s.utf8.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let h = Self.nibble(hi), let l = Self.nibble(lo) else { return nil }
            bytes.append(h << 4 | l)
        }
        self.init(bytes)
    }

    /// 小写十六进制，带 `0x` 前缀。
    public var hexString: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
