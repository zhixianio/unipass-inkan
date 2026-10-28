import Foundation

/// 确定性的测试数据：同样的长度和种子总是得到同样的字节，手机上播放的 GIF 和 App 里的预期一致。
public enum TestPayload {
    public static func bytes(count: Int, seed: UInt64 = 0x554E_4950_4153_53) -> Data {
        // SplitMix64
        var state = seed
        var out = Data(capacity: count)
        while out.count < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            withUnsafeBytes(of: z.bigEndian) { out.append(contentsOf: $0.prefix(count - out.count)) }
        }
        return out
    }
}
