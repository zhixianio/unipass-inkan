import Foundation
import UniPassCore

/// 以太坊的 RLP 编码（只编码，不解码）：交易签名和广播用。
public enum RLP: Equatable, Sendable {
    case bytes(Data)
    case list([RLP])

    /// 整数按大端、去掉前导 0（0 编码成空字节串）。
    public static func uint(_ n: UInt256) -> RLP {
        .bytes(Data(n.bigEndianBytes.drop { $0 == 0 }))
    }

    public static func uint(_ n: UInt64) -> RLP { uint(UInt256(n)) }

    public var encoded: Data {
        switch self {
        case .bytes(let d):
            if d.count == 1, d[d.startIndex] < 0x80 { return d }
            return Self.header(d.count, short: 0x80) + d
        case .list(let items):
            let body = items.reduce(into: Data()) { $0 += $1.encoded }
            return Self.header(body.count, short: 0xC0) + body
        }
    }

    /// 长度 ≤ 55：一个字节 `short + 长度`；否则 `short + 55 + 长度的字节数`，后面跟大端长度。
    static func header(_ length: Int, short: UInt8) -> Data {
        if length <= 55 { return Data([short + UInt8(length)]) }
        let len = Data(withUnsafeBytes(of: UInt64(length).bigEndian, Array.init).drop { $0 == 0 })
        return Data([short + 55 + UInt8(len.count)]) + len
    }
}
