import Foundation
import Testing
@testable import UniPassCore

/// testvectors/ur/bc-ur.json：从 URKit / bc-ur 等参考实现的测试文件里原样取出的向量（来源和许可证见文件头）。
struct URReferenceTests {
    struct Vectors: Decodable {
        struct CRC: Decodable { let utf8: String?; let hex: String?; let crc: String }
        struct PartCBOR: Decodable { let seqNum: UInt32; let seqLen, messageLen: Int; let checksum: UInt32; let data, cbor: String }
        struct BW1: Decodable { let hex, standard, uri, minimal: String; let bad: [[String]] }
        struct BW2: Decodable { let hex, standard, minimal: String }
        struct Seed012: Decodable { let hex, crc, minimal: String }
        struct CBORUR: Decodable { let cbor, ur: String }
        let crc32: [CRC]
        let rng1_wolf_next_mod_100, rng2_crc32wolf_next_mod_100, rng3_wolf_nextInt_1_10: [Int]
        let find_fragment_length: [[Int]]
        let sampler_1_2_4_8_wolf_500: [Int]
        let shuffle_wolf: [[Int]]
        let partition_1024_max100: [String]
        let degrees_1024_max100_wolf_1000: [Int]
        let fragment_chooser_1024_max100_1_50: [[Int]]
        let encoder_cbor_256_max30_20parts: [String]
        let part_cbor: PartCBOR
        let ur_single_bytes_50: String
        let ur_multipart_bytes_256_max30_20parts: [String]
        let bytewords1: BW1
        let bytewords2: BW2
        let bcr_2020_012_seed: Seed012
        let bcr_2020_005_seed, bc_ur_rust_test, ur_rs_crypto_request: CBORUR
    }

    let v: Vectors

    init() throws { v = try loadVectors(Vectors.self, "ur/bc-ur.json") }

    /// 参考测试里的 makeMessage(len, seed: "Wolf")。
    static func makeMessage(_ len: Int) -> Data {
        var rng = Xoshiro256(string: "Wolf")
        return rng.nextData(count: len)
    }

    static func makeMessageUR(_ len: Int) -> UR {
        try! UR(type: "bytes", value: .bytes(makeMessage(len)))
    }

    @Test func crc32() {
        for c in v.crc32 {
            let data = c.utf8.map { Data($0.utf8) } ?? Data(hex: c.hex!)!
            #expect(String(format: "%08x", CRC32.checksum(data)) == c.crc)
        }
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926) // CRC-32/ISO-HDLC 的标准检验值
    }

    @Test func xoshiro() {
        var r1 = Xoshiro256(string: "Wolf")
        #expect((0..<100).map { _ in Int(r1.next() % 100) } == v.rng1_wolf_next_mod_100)
        var r2 = Xoshiro256(seed: CRC32.bigEndianBytes(CRC32.checksum(Data("Wolf".utf8))))
        #expect((0..<100).map { _ in Int(r2.next() % 100) } == v.rng2_crc32wolf_next_mod_100)
        var r3 = Xoshiro256(string: "Wolf")
        #expect((0..<100).map { _ in r3.nextInt(lower: 1, count: 10) } == v.rng3_wolf_nextInt_1_10)
    }

    @Test func sampler() {
        let sampler = RandomSampler([1, 2, 4, 8])
        var rng = Xoshiro256(string: "Wolf")
        #expect((0..<500).map { _ in sampler.next(&rng) } == v.sampler_1_2_4_8_wolf_500)
    }

    @Test func shuffle() {
        // 参考 testShuffle：每个 count 重新播种，部分 Fisher-Yates。
        for (i, expected) in v.shuffle_wolf.enumerated() {
            var rng = Xoshiro256(string: "Wolf")
            var remaining = Array(1...10)
            let got = (0...i).map { _ in remaining.remove(at: rng.nextInt(lower: 0, count: remaining.count)) }
            #expect(got == expected)
        }
    }

    @Test func fragmentLengthAndPartition() {
        for c in v.find_fragment_length {
            #expect(FountainEncoder.nominalFragmentLength(messageLen: c[0], minFragmentLen: c[1], maxFragmentLen: c[2]) == c[3])
        }
        let message = Self.makeMessage(1024)
        #expect(CRC32.checksum(message) == 0x2F19_F3BB)
        let len = FountainEncoder.nominalFragmentLength(messageLen: 1024, minFragmentLen: 10, maxFragmentLen: 100)
        let fragments = FountainEncoder.partition(message, fragmentLen: len)
        #expect(fragments.map { $0.hexString.dropFirst(2) } == v.partition_1024_max100.map { Substring($0) })
    }

    @Test func degreesAndFragmentChooser() {
        let message = Self.makeMessage(1024)
        let chooser = FragmentChooser(seqLen: 11, checksum: CRC32.checksum(message))
        var rng = Xoshiro256(string: "Wolf")
        #expect((0..<1000).map { _ in chooser.degreeSampler.next(&rng) + 1 } == v.degrees_1024_max100_wolf_1000)
        #expect((1...50).map { chooser.chooseFragments(UInt32($0)) } == v.fragment_chooser_1024_max100_1_50)
    }

    @Test func fountainEncoderParts() throws {
        var encoder = FountainEncoder(message: Self.makeMessage(256), maxFragmentLen: 30)
        #expect((0..<20).map { _ in encoder.nextPart().cbor.encoded().hexString } == v.encoder_cbor_256_max30_20parts.map { "0x" + $0 })
        let p = v.part_cbor
        let part = FountainPart(seqNum: p.seqNum, seqLen: p.seqLen, messageLen: p.messageLen, checksum: p.checksum, data: Data(hex: p.data)!)
        #expect(part.cbor.encoded().hexString == "0x" + p.cbor)
        #expect(try FountainPart(cbor: CBOR(decoding: Data(hex: p.cbor)!)) == part)
    }

    @Test func bytewords() throws {
        let b = v.bytewords1
        let data = Data(hex: b.hex)!
        #expect(Bytewords.encode(data, style: .standard) == b.standard)
        #expect(Bytewords.encode(data, style: .uri) == b.uri)
        #expect(Bytewords.encode(data, style: .minimal) == b.minimal)
        #expect(try Bytewords.decode(b.standard, style: .standard) == data)
        #expect(try Bytewords.decode(b.uri, style: .uri) == data)
        #expect(try Bytewords.decode(b.minimal) == data)
        #expect(try Bytewords.decode(b.minimal.uppercased()) == data)
        for bad in b.bad {
            let style: Bytewords.Style = bad[1] == "standard" ? .standard : bad[1] == "uri" ? .uri : .minimal
            #expect(throws: Bytewords.DecodingError.self) { try Bytewords.decode(bad[0], style: style) }
        }
        let d2 = Data(hex: v.bytewords2.hex)!
        #expect(Bytewords.encode(d2, style: .standard) == v.bytewords2.standard)
        #expect(Bytewords.encode(d2) == v.bytewords2.minimal)
        #expect(try Bytewords.decode(v.bytewords2.standard, style: .standard) == d2)
        #expect(try Bytewords.decode(v.bytewords2.minimal) == d2)
        let s = v.bcr_2020_012_seed
        #expect(String(format: "%08x", CRC32.checksum(Data(hex: s.hex)!)) == s.crc)
        #expect(Bytewords.encode(Data(hex: s.hex)!) == s.minimal)
    }

    @Test func singlePartURs() throws {
        let ur = Self.makeMessageUR(50)
        #expect(ur.string == v.ur_single_bytes_50)
        #expect(try UR(parsing: v.ur_single_bytes_50) == ur)
        #expect(try UR(parsing: v.ur_single_bytes_50.uppercased()) == ur)
        for c in [v.bcr_2020_005_seed, v.bc_ur_rust_test, v.ur_rs_crypto_request] {
            let parsed = try UR(parsing: c.ur)
            #expect(parsed.cbor.hexString == "0x" + c.cbor, "\(c.ur)")
            #expect(parsed.string == c.ur)
        }
    }

    @Test func multipartEncodeMatchesReference() {
        var encoder = UREncoder(Self.makeMessageUR(256), maxFragmentLen: 30)
        #expect((0..<20).map { _ in encoder.nextPart() } == v.ur_multipart_bytes_256_max30_20parts)
    }

    @Test func multipartDecodeReferenceParts() throws {
        // 正序、倒序喂参考帧都能解出来。
        for parts in [v.ur_multipart_bytes_256_max30_20parts, Array(v.ur_multipart_bytes_256_max30_20parts.reversed())] {
            var decoder = URDecoder()
            for p in parts where decoder.result == nil { try decoder.receive(p) }
            #expect(try decoder.result?.get() == Self.makeMessageUR(256))
        }
    }

    /// 跳过全部原始分片，只靠混合帧也能解出来（扫码时漏帧的情形）。
    @Test func multipartDecodeFromMixedPartsOnly() throws {
        let ur = Self.makeMessageUR(256)
        var encoder = UREncoder(ur, maxFragmentLen: 30)
        for _ in 0..<encoder.seqLen { _ = encoder.nextPart() }
        var decoder = URDecoder()
        var used = 0
        while decoder.result == nil, used < 200 {
            try decoder.receive(encoder.nextPart())
            used += 1
        }
        #expect(try decoder.result?.get() == ur)
    }

    /// 参考实现的 testMultipartUR：32767 字节，maxFragmentLen 1000，从 seqNum 100 开始。
    @Test func multipartRoundTripLarge() throws {
        let ur = Self.makeMessageUR(32767)
        var encoder = UREncoder(ur, maxFragmentLen: 1000, firstSeqNum: 100)
        var decoder = URDecoder()
        var sent = 0
        while decoder.result == nil {
            try decoder.receive(encoder.nextPart())
            sent += 1
            #expect(sent < 500)
        }
        #expect(try decoder.result?.get() == ur)
    }
}
