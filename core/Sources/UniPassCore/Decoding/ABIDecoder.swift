import Foundation

/// 已识别函数参数用到的 ABI 类型。
public enum ABIType: Hashable, Sendable {
    case address
    /// uintN，N 是 8 的倍数，8…256。
    case uint(Int)
    case bool
    /// 动态 `bytes`。
    case bytes
    /// 动态 `uint256[]`（ERC-1155 `safeBatchTransferFrom` 用）。
    case uintArray
}

public enum ABIValue: Hashable, Sendable {
    case address(Address)
    case uint(UInt256)
    case bool(Bool)
    case bytes(Data)
    case uints([UInt256])

    public var address: Address? { if case .address(let a) = self { a } else { nil } }
    public var uint: UInt256? { if case .uint(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var bytes: Data? { if case .bytes(let d) = self { d } else { nil } }
    public var uints: [UInt256]? { if case .uints(let a) = self { a } else { nil } }
}

/// 边界检查完备的 ABI 解码，只接受**标准编码**：解码后重新编码必须和输入逐字节相同。
/// 于是地址高位、uintN 超宽、bool 不是 0/1、非标准偏移、bytes 末尾补零不是 0、末尾多余字节都会被拒绝
///（Solidity 的解码器对其中一部分是宽容的，比如忽略多余字节；我们不跟进，宁可拒绝）。
public enum ABICodec {
    public static func decode(_ types: [ABIType], _ data: Data) -> [ABIValue]? {
        let bytes = [UInt8](data)
        let headSize = 32 * types.count
        guard bytes.count >= headSize, bytes.count % 32 == 0 else { return nil }
        func word(_ offset: Int) -> ArraySlice<UInt8>? {
            guard offset >= 0, offset <= bytes.count - 32 else { return nil }
            return bytes[offset..<offset + 32]
        }
        func smallInt(_ w: ArraySlice<UInt8>) -> Int? {
            // 偏移和长度不会超过输入长度，前 28 字节必须为 0。
            guard w.prefix(28).allSatisfy({ $0 == 0 }) else { return nil }
            let v = w.suffix(4).reduce(0) { $0 << 8 | Int($1) }
            return v <= bytes.count ? v : nil
        }
        var out: [ABIValue] = []
        for (i, t) in types.enumerated() {
            guard let w = word(32 * i) else { return nil }
            switch t {
            case .address:
                out.append(.address(Address(bytes: Data(w.suffix(20)))!))
            case .uint:
                out.append(.uint(UInt256(bigEndian: Data(w))!))
            case .bool:
                out.append(.bool(w.last == 1))
            case .bytes:
                guard let offset = smallInt(w), let lw = word(offset), let len = smallInt(lw),
                      offset + 32 + len <= bytes.count else { return nil }
                out.append(.bytes(Data(bytes[offset + 32..<offset + 32 + len])))
            case .uintArray:
                guard let offset = smallInt(w), let lw = word(offset), let n = smallInt(lw),
                      n <= (bytes.count - offset - 32) / 32 else { return nil }
                out.append(.uints((0..<n).map { UInt256(bigEndian: Data(bytes[offset + 32 + 32 * $0..<offset + 64 + 32 * $0]))! }))
            }
        }
        guard encode(types, out) == data else { return nil }
        return out
    }

    /// 标准 ABI 编码。值和类型不匹配、或者值超出类型宽度时返回 nil。
    public static func encode(_ types: [ABIType], _ values: [ABIValue]) -> Data? {
        guard types.count == values.count else { return nil }
        var head = Data()
        var tail = Data()
        let headSize = 32 * types.count
        for (t, v) in zip(types, values) {
            switch (t, v) {
            case (.address, .address(let a)):
                head += a.abiEncoded
            case (.uint(let bits), .uint(let n)):
                let b = n.bigEndianBytes
                guard b.prefix(32 - bits / 8).allSatisfy({ $0 == 0 }) else { return nil }
                head += b
            case (.bool, .bool(let x)):
                head += UInt256(x ? 1 : 0).bigEndianBytes
            case (.bytes, .bytes(let d)):
                head += UInt256(UInt64(headSize + tail.count)).bigEndianBytes
                tail += UInt256(UInt64(d.count)).bigEndianBytes + d + Data(count: (32 - d.count % 32) % 32)
            case (.uintArray, .uints(let a)):
                head += UInt256(UInt64(headSize + tail.count)).bigEndianBytes
                tail += UInt256(UInt64(a.count)).bigEndianBytes
                for n in a { tail += n.bigEndianBytes }
            default:
                return nil
            }
        }
        return head + tail
    }
}
