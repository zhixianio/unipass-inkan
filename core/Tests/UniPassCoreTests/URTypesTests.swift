import Foundation
import Testing
@testable import UniPassCore

struct EIP4527Tests {
    struct File: Decodable {
        struct V: Decodable { let id, title, source, ur, cbor: String }
        let vectors: [V]
    }

    let vectors: [String: File.V]

    init() throws {
        vectors = Dictionary(uniqueKeysWithValues: try loadVectors(File.self, "ur/eip4527-keystone.json").vectors.map { ($0.id, $0) })
    }

    /// Keystone 的向量：解码 → 结构 → 重新编码，必须逐字节相同（它们都是合法 dCBOR）。
    @Test func keystoneVectorsRoundTrip() throws {
        for id in ["V1", "V2", "V3"] {
            let v = vectors[id]!
            let ur = try UR(parsing: v.ur)
            #expect(ur.cbor.hexString == "0x" + v.cbor)
            let req = try EthSignRequest(ur: ur)
            #expect(req.ur.string == v.ur, "\(id)")
        }
        for id in ["V5", "V6"] {
            let v = vectors[id]!
            let kp = try CryptoKeypath(cbor: UR(parsing: v.ur).value)
            #expect(try UR(type: "crypto-keypath", value: kp.cbor).string == v.ur)
        }
        // V7：批量请求里嵌入的 eth-sign-request 带 tag 401。
        let batch = try UR(parsing: vectors["V7"]!.ur).value
        let inner = try #require(batch.mapValue?[1]?.arrayValue?.first?.untagged(URTag.ethSignRequest))
        #expect(try EthSignRequest(cbor: inner).ur.string == vectors["V1"]!.ur)
    }

    @Test func keystoneV1Fields() throws {
        let req = try EthSignRequest(ur: UR(parsing: vectors["V1"]!.ur))
        #expect(req.dataType == .transaction)
        #expect(req.chainID == 1)
        #expect(req.origin == "metamask")
        #expect(req.derivationPath == CryptoKeypath(path: "m/44'/1'/1'/0/1", sourceFingerprint: 0x1234_5678))
        let v3 = try EthSignRequest(ur: UR(parsing: vectors["V3"]!.ur))
        #expect(v3.dataType == .typedTransaction && v3.chainID == 43113)
        #expect(v3.derivationPath == CryptoKeypath(path: "m/44'/60'/0'/0/6", sourceFingerprint: 0xBDEE_E782))
    }

    @Test func strictness() throws {
        func req(_ pairs: [(CBOR, CBOR)]) throws -> EthSignRequest { try EthSignRequest(cbor: .map(CBORMap(pairs))) }
        let path = CryptoKeypath(path: "m/44'/60'/0'/0/0", sourceFingerprint: 1)!.taggedCBOR
        let base: [(CBOR, CBOR)] = [(.unsigned(2), .bytes(Data([1]))), (.unsigned(3), .unsigned(2)), (.unsigned(5), path)]
        _ = try req(base)
        #expect(throws: URTypeError.unknownKey) { try req(base + [(.unsigned(8), .null)]) }
        #expect(throws: URTypeError.invalidField(3)) { try req([base[0], (.unsigned(3), .unsigned(5)), base[2]]) }
        #expect(throws: URTypeError.missingField(5)) { try req(Array(base.prefix(2))) }
        #expect(throws: URTypeError.invalidField(5)) { try req([base[0], base[1], (.unsigned(5), .tagged(999, .null))]) }
        #expect(throws: URTypeError.invalidField(1)) {
            try req(base + [(.unsigned(1), .bytes(Data(count: 16)))]) // request-id 没有 tag 37
        }
        #expect(throws: URTypeError.invalidField(6)) { try req(base + [(.unsigned(6), .bytes(Data(count: 19)))]) }
        // 40304 读时接受。
        let v2path = CBOR.tagged(URTag.keypathV2, CryptoKeypath(path: "m/44'/60'/0'/0/0", sourceFingerprint: 1)!.cbor)
        #expect(try req([base[0], base[1], (.unsigned(5), v2path)]).derivationPath.components.count == 5)
        // 空路径必须带指纹；指纹不能是 0。
        #expect(throws: URTypeError.missingField(2)) { try CryptoKeypath(cbor: .map(CBORMap([(.unsigned(1), .array([]))]))) }
        #expect(throws: URTypeError.invalidField(2)) {
            try CryptoKeypath(cbor: .map(CBORMap([(.unsigned(1), .array([])), (.unsigned(2), .unsigned(0))])))
        }
        // 范围形式不支持。
        #expect(throws: URTypeError.invalidField(1)) {
            try CryptoKeypath(cbor: .map(CBORMap([(.unsigned(1), .array([.array([.unsigned(0), .unsigned(5)]), .bool(false)])),
                                                  (.unsigned(2), .unsigned(1))])))
        }
    }
}

struct UniPassURTypesTests {
    static let proxy = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!
    static let factory = Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!
    static let verifiers = Data(hex: "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")!

    static let expectedFingerprint = "7a6d6628"

    static let pairing = SignerPairing(
        x: Data(repeating: 0x11, count: 32), y: Data(repeating: 0x22, count: 32), name: "iPhone",
        biometryPolicy: .anyEnrolled, signerProxy: proxy, verifiers: verifiers, signerFactory: factory)

    /// 手写的期望编码，固定格式（不依赖编码器）。
    @Test func pairingGolden() throws {
        let expected = "a7"
            + "01" + "5820" + String(repeating: "11", count: 32)
            + "02" + "5820" + String(repeating: "22", count: 32)
            + "03" + "66" + "6950686f6e65"
            + "04" + "01"
            + "05" + "54" + "c8f9e2ba66e640b05d6d8da4f00f567679bc9a06"
            + "06" + "56" + "0100445a0683e494ea0c5af3e83c5159fbe47cf9e765"
            + "07" + "54" + "1d31f259ee307358a26dfb23eb365939e8641195"
        #expect(Self.pairing.cbor.encoded().hexString == "0x" + expected)
        #expect(Self.pairing.ur.type == "unipass-pairing")
        #expect(try SignerPairing(ur: UR(parsing: Self.pairing.ur.qrString)) == Self.pairing)
        var noPolicy = Self.pairing
        noPolicy.biometryPolicy = nil
        #expect(try SignerPairing(cbor: noPolicy.cbor) == noPolicy)
    }

    @Test func signerKeyFingerprint() throws {
        // SHA-256(04 ‖ 11×32 ‖ 22×32) 的前 4 字节，用 shasum 独立算出。
        #expect(String(format: "%08x", Self.pairing.keyFingerprint) == Self.expectedFingerprint)
        let kp = Self.pairing.requestKeypath
        #expect(kp.components.isEmpty && kp.sourceFingerprint == Self.pairing.keyFingerprint)
        #expect(try CryptoKeypath(cbor: kp.cbor) == kp)
    }

    @Test func pairingStrictness() throws {
        var entries = Self.pairing.cbor.mapValue!.entries.map { ($0.key, $0.value) }
        func decode(_ e: [(CBOR, CBOR)]) throws -> SignerPairing { try SignerPairing(cbor: .map(CBORMap(e))) }
        #expect(throws: URTypeError.invalidField(4)) { try decode(entries.map { $0.0 == .unsigned(4) ? ($0.0, .unsigned(3)) : $0 }) }
        #expect(throws: URTypeError.invalidField(3)) { try decode(entries.map { $0.0 == .unsigned(3) ? ($0.0, .text("")) : $0 }) }
        #expect(throws: URTypeError.invalidField(3)) {
            try decode(entries.map { $0.0 == .unsigned(3) ? ($0.0, .text(String(repeating: "长", count: 22))) : $0 })
        }
        #expect(throws: URTypeError.invalidField(1)) { try decode(entries.map { $0.0 == .unsigned(1) ? ($0.0, .bytes(Data(count: 33))) : $0 }) }
        #expect(throws: URTypeError.unknownKey) { try decode(entries + [(.unsigned(8), .null)]) }
        entries.removeAll { $0.0 == .unsigned(5) }
        #expect(throws: URTypeError.missingField(5)) { try decode(entries) }
        #expect(throws: URTypeError.wrongURType(expected: "unipass-pairing", got: "unipass-safe")) {
            try SignerPairing(ur: UR(type: "unipass-safe", value: Self.pairing.cbor))
        }
    }

    /// 用真机签名（apps/signer/testdata/device-signature-sts-a-2026-10-25.json）。
    @Test func signatureGoldenFromDevice() throws {
        let proxySig = Data(hex: "0x000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000e0cb344c84dbac8ddb40fd5bf8fd388842e84cafad32943f901b36131245f65f3c48dd2f91f614602fb848872ca874ad4e0ba995f93f163ecfcea473f75316ca1f0000000000000000000000000000000000000000000000000000000000000025bd28ca874e746c460d047bbcd8110dc4eda0ae9f5ca3f002ba659170645f862e0500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003e226f726967696e223a22756e69706173732d7369676e65723a2f2f7365637572652d656e636c617665222c2263726f73734f726967696e223a66616c73650000")!
        let r = UInt256(bigEndian: proxySig[64..<96])!
        let s = UInt256(bigEndian: proxySig[96..<128])!
        let requestID = Data(hex: "0x000102030405060708090a0b0c0d0e0f")!
        let sig = SignerSignature(requestID: requestID, assertion: .signerDefault, signature: P256Signature(r: r, s: s))
        #expect(sig.proxySignature == proxySig)
        let expected = "a5"
            + "01" + "d825" + "50" + "000102030405060708090a0b0c0d0e0f"
            + "02" + "5825" + "bd28ca874e746c460d047bbcd8110dc4eda0ae9f5ca3f002ba659170645f862e" + "05" + "00000000"
            + "03" + "783e" + "226f726967696e223a22756e69706173732d7369676e65723a2f2f7365637572652d656e636c617665222c2263726f73734f726967696e223a66616c7365"
            + "04" + "5820" + "cb344c84dbac8ddb40fd5bf8fd388842e84cafad32943f901b36131245f65f3c"
            + "05" + "5820" + "48dd2f91f614602fb848872ca874ad4e0ba995f93f163ecfcea473f75316ca1f"
        #expect(sig.cbor.encoded().hexString == "0x" + expected)
        #expect(try SignerSignature(ur: UR(parsing: sig.ur.string)) == sig)
    }

    @Test func signatureRejectsHighSAndBadValues() throws {
        let base = SignerSignature(requestID: Data(count: 16), assertion: .signerDefault,
                                   signature: P256Signature(r: UInt256(5), s: UInt256(7)))
        func with(_ key: UInt64, _ value: CBOR) throws -> SignerSignature {
            try SignerSignature(cbor: .map(CBORMap(base.cbor.mapValue!.entries.map { $0.key == .unsigned(key) ? ($0.key, value) : ($0.key, $0.value) })))
        }
        let highS = P256Signature.curveOrder.subtracting(UInt256(7))!
        #expect(throws: URTypeError.invalidField(5)) { try with(5, .bytes(highS.bigEndianBytes)) }
        #expect(throws: URTypeError.invalidField(5)) { try with(5, .bytes(Data(count: 32))) }
        #expect(throws: URTypeError.invalidField(4)) { try with(4, .bytes(P256Signature.curveOrder.bigEndianBytes)) }
        #expect(throws: URTypeError.invalidField(2)) { try with(2, .bytes(Data(count: 36))) }
        #expect(throws: URTypeError.invalidField(1)) { try with(1, .tagged(37, .bytes(Data(count: 15)))) }
    }

    static let safe = SafeRegistration(
        chainID: 11_155_111, safe: Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!,
        proxyFactory: Address(hex: "0x4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67")!,
        singleton: Address(hex: "0x29fcb43b46531bca003ddc8fcb67ffe91900c762")!,
        saltNonce: UInt256(42),
        owners: [proxy, Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!], threshold: 2,
        fallbackHandler: Address(hex: "0xfd0732dc9e303f09fcef3a7388ad10a83459ec99")!, name: "金库")

    @Test func safeGolden() throws {
        let expected = "a9" // 9 个键：1–7、10、14
            + "01" + "1a00aa36a7"
            + "02" + "54" + "8ceb01112162b035be3d38740f8233d28da0e4a1"
            + "03" + "54" + "4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67"
            + "04" + "54" + "29fcb43b46531bca003ddc8fcb67ffe91900c762"
            + "05" + "5820" + String(repeating: "00", count: 31) + "2a"
            + "06" + "82" + "54" + "c8f9e2ba66e640b05d6d8da4f00f567679bc9a06" + "54" + "938313a557b6129d2d8cbda84ad962b1869ab39a"
            + "07" + "02"
            + "0a" + "54" + "fd0732dc9e303f09fcef3a7388ad10a83459ec99"
            + "0e" + "66" + "e98791e5ba93"
        #expect(Self.safe.cbor.encoded().hexString == "0x" + expected)
        #expect(try SafeRegistration(ur: UR(parsing: Self.safe.ur.string)) == Self.safe)
        var full = Self.safe
        full.to = Self.proxy
        full.data = Data([1, 2])
        full.paymentToken = Self.factory
        full.payment = UInt256(1)
        full.paymentReceiver = Self.proxy
        full.name = nil
        #expect(try SafeRegistration(cbor: full.cbor) == full)
    }

    @Test func safeStrictness() throws {
        let entries = Self.safe.cbor.mapValue!.entries.map { ($0.key, $0.value) }
        func decode(_ e: [(CBOR, CBOR)]) throws -> SafeRegistration { try SafeRegistration(cbor: .map(CBORMap(e))) }
        func replacing(_ k: UInt64, _ v: CBOR) -> [(CBOR, CBOR)] { entries.map { $0.0 == .unsigned(k) ? ($0.0, v) : $0 } }
        let owner = CBOR.bytes(Self.proxy.bytes)
        #expect(throws: URTypeError.invalidField(1)) { try decode(replacing(1, .unsigned(0))) }
        #expect(throws: URTypeError.invalidField(6)) { try decode(replacing(6, .array([owner, owner]))) }
        #expect(throws: URTypeError.invalidField(6)) { try decode(replacing(6, .array([.bytes(Data(count: 20))]))) }
        #expect(throws: URTypeError.invalidField(6)) { try decode(replacing(6, .array([.bytes(Data(count: 19) + Data([1]))]))) }
        #expect(throws: URTypeError.invalidField(6)) { try decode(replacing(6, .array([]))) }
        #expect(throws: URTypeError.invalidField(7)) { try decode(replacing(7, .unsigned(3))) }
        #expect(throws: URTypeError.invalidField(7)) { try decode(replacing(7, .unsigned(0))) }
        // 默认值显式写出来不行（只能省略）。
        #expect(throws: URTypeError.invalidField(8)) { try decode(entries + [(.unsigned(8), .bytes(Data(count: 20)))]) }
        #expect(throws: URTypeError.invalidField(9)) { try decode(entries + [(.unsigned(9), .bytes(Data()))]) }
        #expect(throws: URTypeError.invalidField(12)) { try decode(entries + [(.unsigned(12), .bytes(Data(count: 32)))]) }
        #expect(throws: URTypeError.unknownKey) { try decode(entries + [(.unsigned(15), .null)]) }
    }

    @Test func customTagsAreDistinct() {
        let tags: Set<UInt64> = [URTag.unipassPairing, URTag.unipassSignature, URTag.unipassSafe, URTag.uuid,
                                 URTag.cryptoKeypath, URTag.keypathV2, URTag.ethSignRequest]
        #expect(tags.count == 7)
    }
}
