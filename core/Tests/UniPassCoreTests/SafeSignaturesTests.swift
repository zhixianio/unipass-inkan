import Foundation
import Testing
@testable import UniPassCore

struct SafeSignaturesTests {
    let low = Address(hex: "0x1000000000000000000000000000000000000001")!
    let mid = Address(hex: "0x5000000000000000000000000000000000000005")!
    let high = Address(hex: "0xf00000000000000000000000000000000000000f")!

    @Test func sortsByOwnerAndPlacesContractDataAfterStaticPart() throws {
        let eoaSig = Data(repeating: 0xAB, count: 64) + Data([27])
        let contractA = Data(repeating: 0x11, count: 40)
        let contractB = Data(repeating: 0x22, count: 3)

        let encoded = try SafeSignatures.encode([
            .contract(owner: high, signature: contractB),
            .eoa(owner: mid, signature: eoaSig),
            .contract(owner: low, signature: contractA),
        ])

        // 静态部分 3 × 65 = 195 字节，动态部分依次是 low、high 的数据
        #expect(encoded.count == 195 + (32 + 40) + (32 + 3))

        // low：r = 地址，s = 195，v = 0
        #expect(encoded[0..<32] == low.abiEncoded)
        #expect(encoded[32..<64] == UInt256(195).bigEndianBytes)
        #expect(encoded[64] == 0)
        // mid：原样的 EOA 签名
        #expect(encoded[65..<130] == eoaSig)
        // high：偏移跳过 low 的动态数据
        #expect(encoded[130..<162] == high.abiEncoded)
        #expect(encoded[162..<194] == UInt256(195 + 32 + 40).bigEndianBytes)
        #expect(encoded[194] == 0)

        #expect(encoded[195..<227] == UInt256(40).bigEndianBytes)
        #expect(encoded[227..<267] == contractA)
        #expect(encoded[267..<299] == UInt256(3).bigEndianBytes)
        #expect(encoded[299..<302] == contractB)
    }

    @Test func rejectsDuplicateOwnersAndBadEOALength() {
        #expect(throws: SafeSignatures.EncodingError.duplicateOwner(low)) {
            try SafeSignatures.encode([.contract(owner: low, signature: Data()), .contract(owner: low, signature: Data())])
        }
        #expect(throws: SafeSignatures.EncodingError.invalidEOASignatureLength(mid)) {
            try SafeSignatures.encode([.eoa(owner: mid, signature: Data(count: 64))])
        }
    }
}
