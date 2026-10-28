import Foundation
import Testing
@testable import UniPassCore

struct CBORTests {
    /// RFC 8949 Appendix A（Table 6）里本实现支持的条目。
    static let rfcExamples: [(CBOR, String)] = [
        (.unsigned(0), "00"), (.unsigned(1), "01"), (.unsigned(10), "0a"), (.unsigned(23), "17"),
        (.unsigned(24), "1818"), (.unsigned(25), "1819"), (.unsigned(100), "1864"),
        (.unsigned(1000), "1903e8"), (.unsigned(1_000_000), "1a000f4240"),
        (.unsigned(1_000_000_000_000), "1b000000e8d4a51000"),
        (.unsigned(18_446_744_073_709_551_615), "1bffffffffffffffff"),
        (.negative(18_446_744_073_709_551_615), "3bffffffffffffffff"),
        (CBOR(-1), "20"), (CBOR(-10), "29"), (CBOR(-100), "3863"), (CBOR(-1000), "3903e7"),
        (.bool(false), "f4"), (.bool(true), "f5"), (.null, "f6"),
        (.tagged(0, .text("2013-03-21T20:04:00Z")), "c074323031332d30332d32315432303a30343a30305a"),
        (.tagged(1, .unsigned(1_363_896_240)), "c11a514b67b0"),
        (.tagged(23, .bytes(Data([1, 2, 3, 4]))), "d74401020304"),
        (.tagged(24, .bytes(Data(hex: "6449455446")!)), "d818456449455446"),
        (.tagged(32, .text("http://www.example.com")), "d82076687474703a2f2f7777772e6578616d706c652e636f6d"),
        (.bytes(Data()), "40"), (.bytes(Data([1, 2, 3, 4])), "4401020304"),
        (.text(""), "60"), (.text("a"), "6161"), (.text("IETF"), "6449455446"), (.text("\"\\"), "62225c"),
        (.text("\u{00fc}"), "62c3bc"), (.text("\u{6c34}"), "63e6b0b4"), (.text("\u{10151}"), "64f0908591"),
        (.array([]), "80"), (.array([.unsigned(1), .unsigned(2), .unsigned(3)]), "83010203"),
        (.array([.unsigned(1), .array([.unsigned(2), .unsigned(3)]), .array([.unsigned(4), .unsigned(5)])]), "8301820203820405"),
        (.array((1...25).map { .unsigned($0) }), "98190102030405060708090a0b0c0d0e0f101112131415161718181819"),
        (.map(CBORMap()), "a0"),
        (try! .map(CBORMap([(.unsigned(1), .unsigned(2)), (.unsigned(3), .unsigned(4))])), "a201020304"),
        (try! .map(CBORMap([(.text("a"), .unsigned(1)), (.text("b"), .array([.unsigned(2), .unsigned(3)]))])), "a26161016162820203"),
        (try! .array([.text("a"), .map(CBORMap([(.text("b"), .text("c"))]))]), "826161a161626163"),
        (try! .map(CBORMap(["a", "b", "c", "d", "e"].map { (CBOR.text($0), CBOR.text($0.uppercased())) })),
         "a56161614161626142616361436164614461656145"),
    ]

    @Test func rfcExamplesRoundTrip() throws {
        for (value, hex) in Self.rfcExamples {
            #expect(value.encoded().hexString == "0x" + hex)
            #expect(try CBOR(decoding: Data(hex: hex)!) == value, "\(hex)")
        }
    }

    /// RFC 例子里本实现故意不收的：浮点、undefined、其它 simple、不定长、bignum 以外的都能解析但浮点不行。
    @Test func rejectsUnsupportedRFCExamples() {
        for hex in ["f90000", "f93c00", "fb3ff199999999999a", "fa47c35000", "f97e00", "c1fb41d452d9ec200000"] {
            #expect(throws: CBORError.floatNotSupported) { try CBOR(decoding: Data(hex: hex)!) }
        }
        #expect(throws: CBORError.unsupportedSimpleValue(23)) { try CBOR(decoding: Data(hex: "f7")!) }
        #expect(throws: CBORError.unsupportedSimpleValue(16)) { try CBOR(decoding: Data(hex: "f0")!) }
        #expect(throws: CBORError.unsupportedSimpleValue(255)) { try CBOR(decoding: Data(hex: "f8ff")!) }
        for hex in ["5f42010243030405ff", "7f657374726561646d696e67ff", "9fff", "9f018202039f0405ffff",
                    "83018202039f0405ff", "bf61610161629f0203ffff", "bf6346756ef563416d7421ff"] {
            #expect(throws: CBORError.indefiniteLength) { try CBOR(decoding: Data(hex: hex)!) }
        }
    }

    @Test func mapKeysSortedByEncodedBytes() throws {
        // 按编码字节排序：10 (0a) < 100 (1864) < -1 (20) < "z" (617a) < "aa" (626161) < [] (80)
        let m = try CBORMap([(.array([]), .null), (.text("aa"), .null), (.text("z"), .null),
                             (CBOR(-1), .null), (.unsigned(100), .null), (.unsigned(10), .null)])
        #expect(m.entries.map(\.key) == [.unsigned(10), .unsigned(100), CBOR(-1), .text("z"), .text("aa"), .array([])])
        #expect(throws: CBORError.duplicateMapKey) { try CBORMap([(.unsigned(1), .null), (.unsigned(1), .bool(true))]) }
    }

    @Test func strictDecodingRejects() {
        let cases: [(String, CBORError)] = [
            ("1817", .nonShortestEncoding),        // 23 用了 1 字节扩展
            ("190017", .nonShortestEncoding),
            ("1a000000ff", .nonShortestEncoding),
            ("1b00000000ffffffff", .nonShortestEncoding),
            ("5801ff", .nonShortestEncoding),       // 长度 1 用了扩展
            ("d80101", .nonShortestEncoding),       // tag 1 用了扩展
            ("a203040102", .unsortedMapKeys),
            ("a201020103", .duplicateMapKey),
            ("1c", .reservedAdditionalInfo),
            ("ff", .indefiniteLength),
            ("18", .truncated),
            ("4401", .truncated),
            ("83", .truncated),
            ("0000", .trailingBytes),
            ("62c328", .invalidUTF8),
            ("9bffffffffffffffff", .tooManyElements),  // 声明的长度远超输入
            ("bbffffffffffffffff", .tooManyElements),
            ("5bffffffffffffffff", .truncated),
            ("6365cc81", .textNotNFC),              // "e" + U+0301，NFC 应为 U+00E9
        ]
        for (hex, error) in cases {
            #expect(throws: error, "\(hex)") { try CBOR(decoding: Data(hex: hex)!) }
        }
    }

    @Test func limits() {
        let deep = Data(repeating: 0x81, count: 40) + Data([0x00])
        #expect(throws: CBORError.depthExceeded) { try CBOR(decoding: deep) }
        var options = CBORDecodingOptions()
        options.maxItems = 10
        let many = Data([0x8b]) + Data(repeating: 0x00, count: 11)
        #expect(throws: CBORError.tooManyElements) { try CBOR(decoding: many, options: options) }
        #expect(throws: CBORError.inputTooLarge) { try CBOR(decoding: Data(count: 64 * 1024 + 1)) }
    }

    @Test func relaxedOrderingStillRejectsDuplicates() throws {
        var options = CBORDecodingOptions()
        options.requireSortedMapKeys = false
        let m = try CBOR(decoding: Data(hex: "a203040102")!, options: options)
        #expect(m.encoded().hexString == "0xa201020304")
        #expect(throws: CBORError.duplicateMapKey) { try CBOR(decoding: Data(hex: "a3010203040102")!, options: options) }
    }

    /// 固定种子的畸形输入：随机字节和对合法编码的变异。不能崩溃；严格解码成功时，重新编码必须逐字节相同。
    @Test func fuzzDeterministic() {
        var rng = SplitMix64(seed: 0x5AFE_C0DE)
        var accepted = 0
        let seeds = Self.rfcExamples.map { Data(hex: $0.1)! }
        for i in 0..<20_000 {
            var input: Data
            if i % 2 == 0 {
                input = Data((0..<Int(rng.next() % 48)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            } else {
                input = seeds[Int(rng.next() % UInt64(seeds.count))]
                for _ in 0..<(1 + rng.next() % 3) {
                    let op = rng.next() % 3
                    if op == 0, !input.isEmpty {
                        input[Int(rng.next() % UInt64(input.count))] = UInt8(truncatingIfNeeded: rng.next())
                    } else if op == 1, !input.isEmpty {
                        input.remove(at: Int(rng.next() % UInt64(input.count)))
                    } else {
                        input.insert(UInt8(truncatingIfNeeded: rng.next()), at: Int(rng.next() % UInt64(input.count + 1)))
                    }
                }
            }
            if let value = try? CBOR(decoding: input) {
                accepted += 1
                #expect(value.encoded() == input, "\(input.hexString)")
            }
        }
        #expect(accepted > 100)
    }
}

/// 测试用的确定性随机数（SplitMix64）。
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
