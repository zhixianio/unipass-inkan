import Foundation

/// 以太坊用的 Keccak-256（原始 Keccak 填充 0x01，不是 SHA3-256 的 0x06）。
public enum Keccak {
    public static func hash256(_ data: Data) -> Data {
        let rate = 136
        var state = [UInt64](repeating: 0, count: 25)

        var block = [UInt8](data)
        let padLen = rate - block.count % rate
        block.append(contentsOf: [UInt8](repeating: 0, count: padLen))
        block[data.count] ^= 0x01
        block[block.count - 1] ^= 0x80

        for offset in stride(from: 0, to: block.count, by: rate) {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for b in 0..<8 {
                    lane |= UInt64(block[offset + i * 8 + b]) << (8 * UInt64(b))
                }
                state[i] ^= lane
            }
            keccakF(&state)
        }

        var out = Data(capacity: 32)
        for i in 0..<4 {
            for b in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: state[i] >> (8 * UInt64(b))))
            }
        }
        return out
    }

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]
    private static let rotations: [UInt64] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ]
    private static let piLanes: [Int] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ]

    private static func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }

    private static func keccakF(_ st: inout [UInt64]) {
        var bc = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // θ
            for i in 0..<5 {
                bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20]
            }
            for i in 0..<5 {
                let t = bc[(i + 4) % 5] ^ rotl(bc[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) { st[j + i] ^= t }
            }
            // ρ 和 π
            var t = st[1]
            for i in 0..<24 {
                let j = piLanes[i]
                let saved = st[j]
                st[j] = rotl(t, rotations[i])
                t = saved
            }
            // χ
            for j in stride(from: 0, to: 25, by: 5) {
                for i in 0..<5 { bc[i] = st[j + i] }
                for i in 0..<5 { st[j + i] ^= ~bc[(i + 1) % 5] & bc[(i + 2) % 5] }
            }
            // ι
            st[0] ^= roundConstants[round]
        }
    }
}
