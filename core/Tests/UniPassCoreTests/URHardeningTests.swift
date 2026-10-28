import Foundation
import Testing
@testable import UniPassCore

/// 解码器在畸形、伪造和超限输入下的行为：不崩溃、该拒就拒、致命错误后状态不再变化。
struct URHardeningTests {
    static let ur = URReferenceTests.makeMessageUR(256)

    static func parts(_ count: Int, maxFragmentLen: Int = 30) -> [String] {
        var e = UREncoder(ur, maxFragmentLen: maxFragmentLen)
        return (0..<count).map { _ in e.nextPart() }
    }

    static func partString(_ part: FountainPart, type: String = "bytes") -> String {
        "ur:\(type)/\(part.seqNum)-\(part.seqLen)/" + Bytewords.encode(part.cbor.encoded())
    }

    @Test func malformedStrings() {
        let good = Self.ur.string
        let cases: [(String, URError)] = [
            ("", .invalidScheme),
            ("bytes/" + good.dropFirst(9), .invalidScheme),
            ("ur:", .invalidPathLength),
            ("ur:bytes", .invalidPathLength),
            ("ur:bytes/", .invalidPathLength),
            ("ur:bytes//" + good.dropFirst(9), .invalidPathLength),
            ("ur:by_tes/" + good.dropFirst(9), .invalidType),
            ("ur:bytes/1-2/3/4", .invalidPathLength),
            ("ur:bytes/" + good.dropFirst(9).dropLast(2), .bytewords(.invalidChecksum)),
            ("ur:bytes/" + good.dropFirst(9).dropLast(1), .bytewords(.invalidWord)),
            ("ur:bytes/aeadao", .bytewords(.tooShort)),
        ]
        for (s, error) in cases {
            #expect(throws: error, "\(s.prefix(30))") { try UR(parsing: s) }
        }
    }

    @Test func sequenceComponent() throws {
        for bad in ["0-9", "1-0", "01-9", "1-09", "+1-9", "1--9", "1-9-1", "-1-9", "a-9", "4294967296-9", "1-"] {
            #expect(throws: URError.invalidSequenceComponent, "\(bad)") { try URParser.parseSequence(bad) }
        }
        let max = try URParser.parseSequence("4294967295-9")
        #expect(max.seqNum == 4_294_967_295 && max.seqLen == 9)
    }

    @Test func singlePartWithNonCanonicalCBORRejected() {
        // [1, 2, 3] 但 3 写成 0x1803。
        let s = "ur:test/" + Bytewords.encode(Data(hex: "8301021803")!)
        #expect(throws: URError.invalidCBOR(.nonShortestEncoding)) { try UR(parsing: s) }
    }

    @Test func sequenceInStringMustMatchCBOR() throws {
        let p = Self.parts(1)[0]
        let swapped = p.replacingOccurrences(of: "ur:bytes/1-9/", with: "ur:bytes/2-9/")
        var d = URDecoder()
        #expect(throws: URError.sequenceMismatch) { try d.receive(swapped) }
        // 格式错误的单帧不影响后续。
        for s in Self.parts(9) { try d.receive(s) }
        #expect(try d.result?.get() == Self.ur)
    }

    @Test func partsOfOtherMessageIgnored() throws {
        var d = URDecoder()
        let mine = Self.parts(9)
        try d.receive(mine[0])
        var other = UREncoder(URReferenceTests.makeMessageUR(255), maxFragmentLen: 30)
        #expect(try d.receive(other.nextPart()) == .ignored)
        // 别的类型的也忽略。
        let p = try FountainPart(cbor: CBOR(decoding: Bytewords.decode(String(mine[1].split(separator: "/")[2]))))
        #expect(try d.receive(Self.partString(p, type: "other")) == .ignored)
        for s in mine.dropFirst() { try d.receive(s) }
        #expect(try d.result?.get() == Self.ur)
    }

    @Test func singlePartAfterMultipartStartedRejected() throws {
        var d = URDecoder()
        try d.receive(Self.parts(1)[0])
        #expect(throws: URError.unexpectedPartCount) { try d.receive(URReferenceTests.makeMessageUR(10).string) }
    }

    @Test func forgedHeaders() throws {
        // 头部自相矛盾：seqLen 与 messageLen / fragmentLen 对不上。
        var d = URDecoder()
        let forged = FountainPart(seqNum: 1, seqLen: 50, messageLen: 259, checksum: 1, data: Data(count: 29))
        #expect(try d.receive(Self.partString(forged)) == .ignored)

        // 声明的消息超过 64 KB：致命。
        var d2 = URDecoder()
        let huge = FountainPart(seqNum: 1, seqLen: 2, messageLen: 64 * 1024 + 2, checksum: 1, data: Data(count: 32 * 1024 + 1))
        #expect(throws: URError.messageTooLarge) { try d2.receive(Self.partString(huge)) }
        #expect(throws: URError.messageTooLarge) { try d2.receive(Self.parts(1)[0]) }

        // 分片数超过上限：致命（防止 O(seqLen²) 的计算）。
        var d3 = URDecoder()
        let many = FountainPart(seqNum: 1, seqLen: 2000, messageLen: 2000, checksum: 1, data: Data(count: 1))
        #expect(throws: URError.tooManyFragments) { try d3.receive(Self.partString(many)) }

        // 整数越界的帧 CBOR。
        let badCBOR = CBOR.array([.unsigned(1), .unsigned(9), .unsigned(259), .unsigned(1 << 33), .bytes(Data(count: 29))])
        var d4 = URDecoder()
        #expect(throws: URError.invalidPart) { try d4.receive("ur:bytes/1-9/" + Bytewords.encode(badCBOR.encoded())) }
    }

    @Test func wrongChecksumIsFatal() throws {
        // 所有帧都声称同一个错误的校验和：拼完后 CRC 对不上。
        var e = FountainEncoder(message: Self.ur.cbor, maxFragmentLen: 30)
        var d = URDecoder()
        var thrown: URError?
        for _ in 0..<9 {
            var p = e.nextPart()
            p.checksum ^= 1
            do { try d.receive(Self.partString(p)) } catch let error as URError { thrown = error }
        }
        #expect(thrown == .invalidChecksum)
        #expect(throws: URError.invalidChecksum) { try d.receive(Self.parts(1)[0]) }
    }

    @Test func mixedPartsLimit() throws {
        // 约 50 片的消息，只喂混合了 3 片以上的帧，暂存上限设成 2：第 3 个存不下就失败，之后不再接受任何帧。
        let ur = URReferenceTests.makeMessageUR(1500)
        var e = UREncoder(ur, maxFragmentLen: 30)
        #expect(e.seqLen > 40) // 1503 字节的 CBOR，每片不超过 30 字节
        let chooser = FragmentChooser(seqLen: e.seqLen, checksum: CRC32.checksum(ur.cbor))
        var heavy: [String] = []
        while heavy.count < 20 {
            let s = e.nextPart()
            let seqNum = UInt32(s.split(separator: "/")[1].split(separator: "-")[0])!
            if chooser.chooseFragments(seqNum).count >= 3 { heavy.append(s) }
        }
        var limits = FountainDecoder.Limits()
        limits.maxMixedParts = 2
        var d = URDecoder(limits: limits)
        var thrown: URError?
        for s in heavy where thrown == nil {
            do { try d.receive(s) } catch let error as URError { thrown = error }
        }
        #expect(thrown == .decoderStateTooLarge)
        #expect(throws: URError.decoderStateTooLarge) { try d.receive(heavy[0]) }
        // 默认上限（4 × seqLen = 200）下，这些帧都存得下。
        var ok = URDecoder()
        for s in heavy { try ok.receive(s) }
        #expect(ok.result == nil)
    }

    @Test func maxPartsLimit() throws {
        var limits = FountainDecoder.Limits()
        limits.maxParts = 5
        var d = URDecoder(limits: limits)
        let parts = Self.parts(9)
        for p in parts.prefix(5) { try d.receive(p) }
        #expect(throws: URError.tooManyParts) { try d.receive(parts[5]) }
    }

    /// 固定种子：对合法帧随机改字符、截断、拼接。不能崩溃；解出的 bytes 类型结果必须等于原消息。
    @Test func fuzzDecoder() {
        var rng = SplitMix64(seed: 0xC0FF_EE)
        let parts = Self.parts(40)
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789/-:")
        for _ in 0..<300 {
            var d = URDecoder()
            for _ in 0..<30 {
                var s = Array(parts[Int(rng.next() % UInt64(parts.count))])
                switch rng.next() % 4 {
                case 0: s[Int(rng.next() % UInt64(s.count))] = letters[Int(rng.next() % UInt64(letters.count))]
                case 1: s = Array(s.prefix(Int(rng.next() % UInt64(s.count))))
                case 2: s += Array(parts[Int(rng.next() % UInt64(parts.count))].dropFirst(9))
                default: break
                }
                _ = try? d.receive(String(s))
            }
            // 变异可能恰好拼出另一个合法类型的单帧 UR（例如把 "/" 改成字母：ur:bytesx16-9/…），
            // 那是合法输入，类型由调用方检查。只要类型还是 bytes，内容就必须是原消息。
            if case .success(let ur)? = d.result, ur.type == "bytes" { #expect(ur == Self.ur) }
        }
    }
}
