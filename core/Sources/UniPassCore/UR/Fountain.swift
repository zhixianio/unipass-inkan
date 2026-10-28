import CryptoKit
import Foundation

// 多帧 UR 的喷泉码（BCR-2024-001），算法逐项对齐参考实现 URKit / bc-ur，
// 这样编码出的每一帧和 Keystone、AirGap 等用的实现逐字节相同。

/// Xoshiro256**，种子 = SHA-256(seed) 读成 4 个大端 UInt64。
struct Xoshiro256 {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    init(seed: some Sequence<UInt8>) {
        let digest = Array(SHA256.hash(data: Data(seed)))
        func word(_ i: Int) -> UInt64 { digest[i * 8..<i * 8 + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        s = (word(0), word(1), word(2), word(3))
    }

    init(string: String) { self.init(seed: Array(string.utf8)) }

    mutating func next() -> UInt64 {
        func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }
        let result = rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = rotl(s.3, 45)
        return result
    }

    /// 参考实现是 `Double(next()) / 2^64`，`next()` 接近 2^64 时会舍入成 1.0（概率约 2^-54），
    /// 让后面的下标越界。这里夹到 1 以下；所有测试向量都不受影响。
    mutating func nextDouble() -> Double {
        min(Double(next()) / 18_446_744_073_709_551_616.0, 1.0.nextDown)
    }

    /// `[lower, lower + count)` 里的整数。
    mutating func nextInt(lower: Int, count: Int) -> Int {
        Int(nextDouble() * Double(count)) + lower
    }

    mutating func nextByte() -> UInt8 { UInt8(nextInt(lower: 0, count: 256)) }

    mutating func nextData(count: Int) -> Data { Data((0..<count).map { _ in nextByte() }) }
}

/// Vose alias 采样，按参考实现的写法（填 S / L 时下标倒序）。
struct RandomSampler {
    let probs: [Double]
    let aliases: [Int]

    init(_ weights: [Double]) {
        let n = weights.count
        let sum = weights.reduce(0, +)
        var p = weights.map { $0 * Double(n) / sum }
        var small: [Int] = []
        var large: [Int] = []
        for i in (0..<n).reversed() {
            if p[i] < 1 { small.append(i) } else { large.append(i) }
        }
        var probs = [Double](repeating: 0, count: n)
        var aliases = [Int](repeating: 0, count: n)
        while !small.isEmpty, !large.isEmpty {
            let a = small.removeLast()
            let g = large.removeLast()
            probs[a] = p[a]
            aliases[a] = g
            p[g] += p[a] - 1
            if p[g] < 1 { small.append(g) } else { large.append(g) }
        }
        while let g = large.popLast() { probs[g] = 1 }
        while let a = small.popLast() { probs[a] = 1 }
        self.probs = probs
        self.aliases = aliases
    }

    func next(_ rng: inout Xoshiro256) -> Int {
        let r1 = rng.nextDouble()
        let r2 = rng.nextDouble()
        let i = Int(Double(probs.count) * r1)
        return r2 < probs[i] ? i : aliases[i]
    }
}

/// 第 seqNum 帧混了哪几个分片（升序）。
struct FragmentChooser {
    let seqLen: Int
    let checksum: UInt32
    let degreeSampler: RandomSampler

    init(seqLen: Int, checksum: UInt32) {
        self.seqLen = seqLen
        self.checksum = checksum
        degreeSampler = RandomSampler((1...seqLen).map { 1 / Double($0) })
    }

    func chooseFragments(_ seqNum: UInt32) -> [Int] {
        // 前 seqLen 帧是不混合的原始分片。
        if seqNum <= seqLen { return [Int(seqNum) - 1] }
        var rng = Xoshiro256(seed: CRC32.bigEndianBytes(seqNum) + CRC32.bigEndianBytes(checksum))
        let degree = degreeSampler.next(&rng) + 1
        var remaining = Array(0..<seqLen)
        var chosen: [Int] = []
        chosen.reserveCapacity(degree)
        while chosen.count < degree {
            chosen.append(remaining.remove(at: rng.nextInt(lower: 0, count: remaining.count)))
        }
        return chosen.sorted()
    }
}

/// 一帧的内容：`[seqNum, seqLen, messageLen, checksum, data]`。
public struct FountainPart: Hashable, Sendable {
    public var seqNum: UInt32
    public var seqLen: Int
    public var messageLen: Int
    public var checksum: UInt32
    public var data: Data

    public var cbor: CBOR {
        .array([.unsigned(UInt64(seqNum)), .unsigned(UInt64(seqLen)), .unsigned(UInt64(messageLen)),
                .unsigned(UInt64(checksum)), .bytes(data)])
    }

    /// 严格解析；整数越界、字段类型不对、长度为 0 都拒绝。
    public init(cbor: CBOR) throws {
        guard let a = cbor.arrayValue, a.count == 5,
              let seqNum = a[0].uint, seqNum >= 1, seqNum <= UInt32.max,
              let seqLen = a[1].uint, seqLen >= 1, seqLen <= UInt64(Int32.max),
              let messageLen = a[2].uint, messageLen >= 1, messageLen <= UInt64(Int32.max),
              let checksum = a[3].uint, checksum <= UInt32.max,
              let data = a[4].bytesValue, !data.isEmpty
        else { throw URError.invalidPart }
        self.init(seqNum: UInt32(seqNum), seqLen: Int(seqLen), messageLen: Int(messageLen),
                  checksum: UInt32(checksum), data: data)
    }

    public init(seqNum: UInt32, seqLen: Int, messageLen: Int, checksum: UInt32, data: Data) {
        self.seqNum = seqNum
        self.seqLen = seqLen
        self.messageLen = messageLen
        self.checksum = checksum
        self.data = data
    }
}

public struct FountainEncoder: Sendable {
    public let messageLen: Int
    public let checksum: UInt32
    public let fragmentLen: Int
    let fragments: [Data]
    let chooser: FragmentChooser
    public private(set) var seqNum: UInt32

    public var seqLen: Int { fragments.count }
    /// 已经发出过全部原始分片。
    public var isComplete: Bool { seqNum >= seqLen }

    /// `minFragmentLen` 默认 10，和参考实现一致（测试向量依赖它）。
    public init(message: Data, maxFragmentLen: Int, minFragmentLen: Int = 10, firstSeqNum: UInt32 = 0) {
        precondition(!message.isEmpty && maxFragmentLen > 0 && minFragmentLen > 0)
        messageLen = message.count
        checksum = CRC32.checksum(message)
        fragmentLen = Self.nominalFragmentLength(messageLen: message.count, minFragmentLen: minFragmentLen,
                                                 maxFragmentLen: maxFragmentLen)
        fragments = Self.partition(message, fragmentLen: fragmentLen)
        chooser = FragmentChooser(seqLen: fragments.count, checksum: checksum)
        seqNum = firstSeqNum
    }

    /// 参考实现的 findNominalFragmentLength。和参考实现一样：最小长度起作用时结果可能大于 maxFragmentLen
    ///（例如 (48, 10, 10) → 12）。参考实现在 messageLen < minFragmentLen 时会崩，这里改为整条一片。
    static func nominalFragmentLength(messageLen: Int, minFragmentLen: Int, maxFragmentLen: Int) -> Int {
        let maxFragmentCount = messageLen / minFragmentLen
        guard maxFragmentCount >= 1 else { return messageLen }
        var fragmentLen = messageLen
        for fragmentCount in 1...maxFragmentCount {
            fragmentLen = (messageLen + fragmentCount - 1) / fragmentCount
            if fragmentLen <= maxFragmentLen { break }
        }
        return fragmentLen
    }

    static func partition(_ message: Data, fragmentLen: Int) -> [Data] {
        stride(from: 0, to: message.count, by: fragmentLen).map { start in
            var f = Data(message[message.startIndex + start..<message.startIndex + min(start + fragmentLen, message.count)])
            if f.count < fragmentLen { f.append(Data(count: fragmentLen - f.count)) }
            return f
        }
    }

    public mutating func nextPart() -> FountainPart {
        seqNum &+= 1
        let indexes = chooser.chooseFragments(seqNum)
        var data = fragments[indexes[0]]
        for i in indexes.dropFirst() { data.xor(fragments[i]) }
        return FountainPart(seqNum: seqNum, seqLen: seqLen, messageLen: messageLen, checksum: checksum, data: data)
    }
}

extension Data {
    mutating func xor(_ other: Data) {
        precondition(count == other.count)
        withUnsafeMutableBytes { a in
            other.withUnsafeBytes { b in
                for i in 0..<a.count { a[i] ^= b[i] }
            }
        }
    }
}

/// 喷泉码解码器。归约算法和参考实现相同（FIFO 队列、按真子集异或），但用有序容器，结果和
/// 所需帧数都确定。比参考实现多的检查：头部各字段的自洽性、消息大小和帧数上限。
public struct FountainDecoder: Sendable {
    public struct Limits: Sendable {
        /// 消息最大字节数。
        public var maxMessageLen = 64 * 1024
        /// 最多分成多少片（限制每帧的计算量：混合帧的选取是 O(seqLen²)）。
        /// 我们最大的消息（带 SafeTx JSON 的签名请求）只有几 KB，256 片绰绰有余。
        public var maxSeqLen = 256
        /// 最多接收多少帧（含被丢弃的），超过就失败。正常扫码只需要 seqLen 的一两倍。
        public var maxParts = 2_000
        /// 暂存的混合帧最多多少个；nil 表示 seqLen 的 4 倍。恶意发送方可以构造大量互不相同的
        /// 分片组合，没有这个上限时内存和每帧的归约开销都会无限增长。
        public var maxMixedParts: Int?

        public init() {}
    }

    func mixedLimit(seqLen: Int) -> Int { limits.maxMixedParts ?? seqLen * 4 }

    public enum Outcome: Hashable, Sendable {
        /// 这一帧有用或重复，继续扫。
        case accepted
        /// 和已收到的帧不属于同一条消息，丢弃。
        case ignored
    }

    struct MixedPart: Sendable {
        var indexes: [Int]
        var data: Data
    }

    public let limits: Limits
    var expected: (seqLen: Int, messageLen: Int, checksum: UInt32, fragmentLen: Int)?
    var chooser: FragmentChooser?
    var simple: [Int: Data] = [:]
    var mixed: [[Int]: MixedPart] = [:]
    var mixedOrder: [[Int]] = []
    var queue: [MixedPart] = []
    public private(set) var processedParts = 0
    public private(set) var result: Result<Data, URError>?

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var expectedFragmentCount: Int? { expected?.seqLen }
    public var receivedFragmentCount: Int { simple.count }

    public mutating func receive(_ part: FountainPart) throws -> Outcome {
        if case .failure(let e)? = result { throw e }
        guard result == nil else { return .ignored }
        processedParts += 1
        guard processedParts <= limits.maxParts else { return try fail(.tooManyParts) }

        if let e = expected {
            guard part.seqLen == e.seqLen, part.messageLen == e.messageLen, part.checksum == e.checksum,
                  part.data.count == e.fragmentLen else { return .ignored }
        } else {
            guard part.messageLen <= limits.maxMessageLen else { return try fail(.messageTooLarge) }
            guard part.seqLen <= limits.maxSeqLen else { return try fail(.tooManyFragments) }
            // 分片数必须正好是 ceil(messageLen / fragmentLen)，否则是伪造或损坏的头部。
            let fragmentLen = part.data.count
            guard part.seqLen == (part.messageLen + fragmentLen - 1) / fragmentLen else { return .ignored }
            expected = (part.seqLen, part.messageLen, part.checksum, fragmentLen)
            chooser = FragmentChooser(seqLen: part.seqLen, checksum: part.checksum)
        }

        queue.append(MixedPart(indexes: chooser!.chooseFragments(part.seqNum), data: part.data))
        while result == nil, !queue.isEmpty {
            let p = queue.removeFirst()
            if p.indexes.count == 1 { processSimple(p) } else { processMixed(p) }
        }
        if case .failure(let e)? = result { throw e }
        return .accepted
    }

    private mutating func fail(_ e: URError) throws -> Outcome {
        result = .failure(e)
        throw e
    }

    private mutating func processSimple(_ p: MixedPart) {
        let index = p.indexes[0]
        guard simple[index] == nil else { return }
        simple[index] = p.data
        guard let e = expected, simple.count == e.seqLen else {
            reduceMixed(by: p)
            return
        }
        var message = Data(capacity: e.seqLen * e.fragmentLen)
        for i in 0..<e.seqLen { message += simple[i]! }
        message = message.prefix(e.messageLen)
        result = CRC32.checksum(message) == e.checksum ? .success(message) : .failure(.invalidChecksum)
    }

    private mutating func processMixed(_ p: MixedPart) {
        guard mixed[p.indexes] == nil else { return }
        var reduced = p
        for (i, d) in simple.sorted(by: { $0.key < $1.key }) {
            reduced = Self.reduce(reduced, by: MixedPart(indexes: [i], data: d))
        }
        for key in mixedOrder {
            reduced = Self.reduce(reduced, by: mixed[key]!)
        }
        if reduced.indexes.count == 1 {
            queue.append(reduced)
        } else {
            reduceMixed(by: reduced)
            mixed[reduced.indexes] = reduced
            mixedOrder.append(reduced.indexes)
            if let e = expected, mixed.count > mixedLimit(seqLen: e.seqLen) {
                result = .failure(.decoderStateTooLarge)
            }
        }
    }

    private mutating func reduceMixed(by p: MixedPart) {
        var newOrder: [[Int]] = []
        var newMixed: [[Int]: MixedPart] = [:]
        for key in mixedOrder {
            let r = Self.reduce(mixed[key]!, by: p)
            if r.indexes.count == 1 {
                queue.append(r)
            } else if newMixed[r.indexes] == nil {
                newMixed[r.indexes] = r
                newOrder.append(r.indexes)
            }
        }
        mixed = newMixed
        mixedOrder = newOrder
    }

    /// b 的分片集合是 a 的真子集时，a 去掉 b。两边的下标都是升序。
    static func reduce(_ a: MixedPart, by b: MixedPart) -> MixedPart {
        guard b.indexes.count < a.indexes.count, Set(b.indexes).isSubset(of: a.indexes) else { return a }
        var data = a.data
        data.xor(b.data)
        return MixedPart(indexes: a.indexes.filter { !b.indexes.contains($0) }, data: data)
    }
}
