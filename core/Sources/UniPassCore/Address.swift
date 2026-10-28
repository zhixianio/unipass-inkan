import Foundation

/// 20 字节以太坊地址。
public struct Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public static let zero = Address(unchecked: Data(repeating: 0, count: 20))

    public init?(bytes: Data) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }

    /// 解析十六进制地址。全小写或全大写直接接受；大小写混合时必须是正确的 EIP-55 校验和。
    public init?(hex: String) {
        guard let data = Data(hex: hex), data.count == 20 else { return nil }
        self.bytes = data
        let body = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        let isMixedCase = body != body.lowercased() && body != body.uppercased()
        if isMixedCase && body != String(checksummed.dropFirst(2)) { return nil }
    }

    /// EIP-55 校验和格式。
    public var checksummed: String {
        let lower = bytes.hexString.dropFirst(2)
        let hash = Keccak.hash256(Data(lower.utf8))
        var out = "0x"
        for (i, c) in lower.enumerated() {
            let nibble = (hash[i / 2] >> (i % 2 == 0 ? 4 : 0)) & 0x0F
            out.append(nibble >= 8 ? Character(c.uppercased()) : c)
        }
        return out
    }

    /// ABI 编码：左侧补零到 32 字节。
    public var abiEncoded: Data {
        Data(repeating: 0, count: 12) + bytes
    }

    public var description: String { checksummed }

    /// 按数值大小比较，Safe 要求签名按 owner 地址升序排列。
    public static func < (lhs: Address, rhs: Address) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}
