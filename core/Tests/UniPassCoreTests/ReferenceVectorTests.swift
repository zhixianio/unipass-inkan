import Foundation
import Testing
@testable import UniPassCore

/// 对照 testvectors/ 里由 viem 生成的参考结果。
struct ReferenceVectorTests {
    struct KeccakVector: Decodable { let input: String; let hash: String }
    struct AddressVector: Decodable { let lower: String; let checksummed: String }
    struct UInt256Vector: Decodable { let decimal: String; let bytes32: String }
    struct SafeTxVector: Decodable {
        struct Tx: Decodable {
            let to, value, data: String
            let operation: UInt8
            let safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, nonce: String
        }
        let chainId, safe: String
        let tx: Tx
        let safeTxHash: String
    }
    struct WebAuthnABIVector: Decodable {
        let authenticatorData, clientDataFields, r, s, encoded: String
    }

    @Test func keccak256() throws {
        for v in try loadVectors([KeccakVector].self, "keccak256.json") {
            #expect(Keccak.hash256(Data(hex: v.input)!).hexString == v.hash, "input length \(v.input.count / 2 - 1)")
        }
    }

    @Test func addressChecksum() throws {
        for v in try loadVectors([AddressVector].self, "address.json") {
            let address = try #require(Address(hex: v.lower))
            #expect(address.checksummed == v.checksummed)
            #expect(Address(hex: v.checksummed) == address)
        }
    }

    @Test func uint256Encoding() throws {
        for v in try loadVectors([UInt256Vector].self, "uint256.json") {
            let n = try #require(UInt256(decimal: v.decimal))
            #expect(n.bigEndianBytes.hexString == v.bytes32)
            #expect(n.description == v.decimal)
            #expect(UInt256(hex: v.bytes32) == n)
        }
    }

    @Test func safeTxHash() throws {
        for v in try loadVectors([SafeTxVector].self, "safetx.json") {
            let tx = try SafeTx(
                to: #require(Address(hex: v.tx.to)),
                value: #require(UInt256(decimal: v.tx.value)),
                data: #require(Data(hex: v.tx.data)),
                operation: #require(SafeTx.Operation(rawValue: v.tx.operation)),
                safeTxGas: #require(UInt256(decimal: v.tx.safeTxGas)),
                baseGas: #require(UInt256(decimal: v.tx.baseGas)),
                gasPrice: #require(UInt256(decimal: v.tx.gasPrice)),
                gasToken: #require(Address(hex: v.tx.gasToken)),
                refundReceiver: #require(Address(hex: v.tx.refundReceiver)),
                nonce: #require(UInt256(decimal: v.tx.nonce))
            )
            let hash = try tx.hash(chainId: #require(UInt256(decimal: v.chainId)), safe: #require(Address(hex: v.safe)))
            #expect(hash.hexString == v.safeTxHash)
        }
    }

    @Test func webAuthnSignatureABI() throws {
        for v in try loadVectors([WebAuthnABIVector].self, "webauthn-abi.json") {
            let assertion = try WebAuthnAssertion(
                authenticatorData: #require(Data(hex: v.authenticatorData)),
                clientDataFields: v.clientDataFields
            )
            let sig = try P256Signature(r: #require(UInt256(hex: v.r)), s: #require(UInt256(hex: v.s)))
            #expect(assertion.abiEncoded(signature: sig).hexString == v.encoded)
        }
    }
}

func loadVectors<T: Decodable>(_ type: T.Type, _ name: String, filePath: String = #filePath) throws -> T {
    let url = URL(fileURLWithPath: filePath)
        .deletingLastPathComponent() // UniPassCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // core
        .deletingLastPathComponent() // 仓库根目录
        .appending(path: "testvectors/\(name)")
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}
