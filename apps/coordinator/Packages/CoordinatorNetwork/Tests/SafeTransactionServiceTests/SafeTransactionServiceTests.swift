import Foundation
import Testing
import UniPassCore
@testable import SafeTransactionService

@Suite struct STSSignatureTests {
    @Test func contractSignatureLayout() throws {
        let owner = try #require(Address(hex: "0x1111111111111111111111111111111111111111"))
        let inner = Data(repeating: 0xAB, count: 40)
        let encoded = STSSignature.contract(owner: owner, signature: inner)

        #expect(encoded.count == 65 + 32 + 40)
        #expect(encoded.prefix(32) == owner.abiEncoded) // r = owner
        #expect(encoded[32..<64] == UInt256(65).bigEndianBytes) // s = 偏移
        #expect(encoded[64] == 0) // v = 0：合约签名
        #expect(encoded[65..<97] == UInt256(40).bigEndianBytes)
        #expect(encoded.suffix(40) == inner)
    }
}

@Suite struct OwnerSignatureTests {
    @Test func contractSignatureRoundTrip() throws {
        let owner = try #require(Address(hex: "0xc8f9e2ba66e640b05d6d8da4f00f567679bc9a06"))
        let inner = Data((0..<320).map { UInt8($0 & 0xFF) })
        let wrapped = STSSignature.contract(owner: owner, signature: inner)
        #expect(try MultisigTransaction.contractData(wrapped, owner: owner) == inner)
    }

    @Test func rejectsWrongOwner() throws {
        let owner = try #require(Address(hex: "0x1111111111111111111111111111111111111111"))
        let other = try #require(Address(hex: "0x2222222222222222222222222222222222222222"))
        let wrapped = STSSignature.contract(owner: owner, signature: Data(repeating: 1, count: 64))
        #expect(throws: STSError.self) { try MultisigTransaction.contractData(wrapped, owner: other) }
    }
}

@Suite struct STSModelTests {
    /// STS v2 的真实响应结构（字段取自 Sepolia，数值精简）。
    static let sample = #"""
    {
      "safe": "0x5298A93734C3D979eF1f23F78eBB871879A21F22",
      "to": "0x5298A93734C3D979eF1f23F78eBB871879A21F22",
      "value": "0",
      "data": null,
      "operation": 0,
      "gasToken": "0x0000000000000000000000000000000000000000",
      "safeTxGas": "0",
      "baseGas": "0",
      "gasPrice": "0",
      "refundReceiver": "0x0000000000000000000000000000000000000000",
      "nonce": "3",
      "safeTxHash": "0x00",
      "proposer": null,
      "isExecuted": false,
      "transactionHash": null,
      "confirmationsRequired": 2,
      "confirmations": [
        {"owner": "0x1111111111111111111111111111111111111111", "signature": "0x", "signatureType": "CONTRACT_SIGNATURE", "submissionDate": "2026-10-25T00:00:00Z"}
      ],
      "trusted": true,
      "submissionDate": "2026-10-25T00:00:00Z"
    }
    """#

    @Test func decodesV2TransactionAndBuildsSafeTx() throws {
        let tx = try JSONDecoder().decode(MultisigTransaction.self, from: Data(Self.sample.utf8))
        let safeTx = try tx.safeTx()
        #expect(safeTx.nonce == UInt256(3))
        #expect(safeTx.data.isEmpty)
        #expect(tx.confirmations?.first?.signatureType == "CONTRACT_SIGNATURE")
    }

    @Test func uintAcceptsStringOrNumber() throws {
        let values = try JSONDecoder().decode([STSUInt].self, from: Data(#"["115792089237316195423570985008687907853269984665640564039457584007913129639935", 7]"#.utf8))
        #expect(values[0].value == .max)
        #expect(values[1].value == UInt256(7))
    }

    @Test func proposeBodyUsesChecksummedAddressesAndDecimalStrings() throws {
        let body = ProposeBody(
            safe: "0xS", to: "0xT", value: "1000000000000000000", data: nil, operation: 0, gasToken: "0x0",
            safeTxGas: "0", baseGas: "0", gasPrice: "0", refundReceiver: "0x0", nonce: "5",
            contractTransactionHash: "0xH", sender: "0xO", signature: "0xSIG", origin: nil
        )
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["value"] as? String == "1000000000000000000")
        #expect(json["contractTransactionHash"] as? String == "0xH")
    }
}

@Suite struct QueueStatusTests {
    func tx(executed: Bool = false, nonce: Int = 3, confirmations: Int = 1, successful: String = "null",
            submitted: String = "2026-10-26T00:31:20.681723Z", executedAt: String = "null", hash: String = "0x00") throws -> MultisigTransaction {
        let c = (0..<confirmations).map { i in
            #"{"owner": "0x\#(String(repeating: String(i + 1), count: 40))", "signature": "0x", "signatureType": "EOA", "submissionDate": null}"#
        }.joined(separator: ",")
        let json = STSModelTests.sample
            .replacingOccurrences(of: #""isExecuted": false"#, with: #""isExecuted": \#(executed), "isSuccessful": \#(successful), "executionDate": \#(executedAt)"#)
            .replacingOccurrences(of: #""nonce": "3""#, with: #""nonce": "\#(nonce)""#)
            .replacingOccurrences(of: #""submissionDate": "2026-10-25T00:00:00Z"\#n}"#, with: #""submissionDate": "\#(submitted)"\#n}"#)
            .replacing(#/"confirmations": \[[^\]]*\]/#, with: #""confirmations": [\#(c)]"#)
            .replacingOccurrences(of: #""safeTxHash": "0x00""#, with: #""safeTxHash": "\#(hash)""#)
        return try JSONDecoder().decode(MultisigTransaction.self, from: Data(json.utf8))
    }

    @Test func statuses() throws {
        #expect(try tx(confirmations: 1).status(safeNonce: UInt256(3)) == .awaitingSignatures(collected: 1, required: 2))
        #expect(try tx(confirmations: 2).status(safeNonce: UInt256(3)) == .ready)
        #expect(try tx(confirmations: 1).status(safeNonce: UInt256(4)) == .replaced)
        #expect(try tx(confirmations: 1).status(safeNonce: nil) == .awaitingSignatures(collected: 1, required: 2))
        #expect(try tx(executed: true, nonce: 1, confirmations: 2, successful: "true").status(safeNonce: UInt256(4)) == .executed(succeeded: true))
        #expect(try tx(executed: true, confirmations: 2, successful: "false").status(safeNonce: UInt256(4)) == .executed(succeeded: false))
    }

    @Test func mergeKeepsNewerKnownState() throws {
        let listed = try tx(confirmations: 1)
        let signed = try tx(confirmations: 2)
        let executed = try tx(executed: true, confirmations: 2, successful: "true")
        // 列表落后：本地已知的签名和上链状态保留。
        #expect(MultisigTransaction.merge(fetched: [listed], known: [signed]) == [signed])
        #expect(MultisigTransaction.merge(fetched: [signed], known: [executed]) == [executed])
        // 列表更新时用列表；本地没有的照列表。
        #expect(MultisigTransaction.merge(fetched: [executed], known: [listed]) == [executed])
        #expect(MultisigTransaction.merge(fetched: [listed], known: []) == [listed])
    }

    /// 链上 nonce 先过、交易服务还没标成已执行：签满的显示"正在确认"，不是"已被替换"。
    @Test func justExecutedIsConfirmingNotReplaced() throws {
        let signed = try tx(nonce: 3, confirmations: 2)
        #expect(signed.status(safeNonce: UInt256(4)) == .confirming)
        #expect(try tx(nonce: 3, confirmations: 1).status(safeNonce: UInt256(4)) == .replaced)
        let other = try tx(executed: true, nonce: 3, confirmations: 2, successful: "true", hash: "0x" + String(repeating: "ab", count: 32))
        #expect(signed.status(safeNonce: UInt256(4), siblings: [signed, other]) == .replaced)
    }

    @Test func confirmingTimesOutAfterTwoMinutes() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(QueueStatus.confirming.timingOut(since: start, now: start.addingTimeInterval(119)) == .confirming)
        #expect(QueueStatus.confirming.timingOut(since: start, now: start.addingTimeInterval(120)) == .unconfirmed)
        #expect(QueueStatus.confirming.timingOut(since: nil, now: start) == .confirming)
        #expect(QueueStatus.ready.timingOut(since: start, now: start.addingTimeInterval(600)) == .ready)
    }

    @Test func confirmationsAndDates() throws {
        let t = try tx(confirmations: 1)
        #expect(t.hasConfirmation(from: Address(hex: "0x1111111111111111111111111111111111111111")!))
        #expect(!t.hasConfirmation(from: Address(hex: "0x2222222222222222222222222222222222222222")!))
        #expect(abs(try #require(t.date).timeIntervalSince1970 - 1_792_974_680.681) < 0.001)
        let executed = try tx(executed: true, confirmations: 2, executedAt: #""2026-10-26T00:32:12Z""#)
        #expect(executed.date == Date(timeIntervalSince1970: 1_792_974_732))
    }
}

/// 自己填的 RPC 节点：写法、链 ID 核对、打码、存储格式；钥匙串条目按 Bundle ID 分开。
@Suite struct RPCEndpointsTests {
    @Test func acceptsHTTPSAndLocalHTTPOnly() throws {
        #expect(try RPCEndpoints.parse("https://eth-sepolia.example.com/v2/abc").get().host == "eth-sepolia.example.com")
        #expect(try RPCEndpoints.parse("  http://localhost:8545  ").get().port == 8545)
        #expect((try? RPCEndpoints.parse("http://127.0.0.1:8545").get()) != nil)
        #expect(RPCEndpoints.parse("http://rpc.example.com") == .failure(.notHTTPS))
        #expect(RPCEndpoints.parse("ftp://rpc.example.com") == .failure(.notAURL))
        #expect(RPCEndpoints.parse("not a url") == .failure(.notAURL))
        #expect(RPCEndpoints.parse("") == .failure(.notAURL))
    }

    @Test func checksTheChainBeforeSaving() async {
        struct Down: Error {}
        let ok = await RPCEndpoints.validate("https://node.example.com", chainID: 11_155_111) { _ in 11_155_111 }
        #expect((try? ok.get()) == URL(string: "https://node.example.com"))
        #expect(await RPCEndpoints.validate("https://node.example.com", chainID: 11_155_111) { _ in 1 } == .failure(.wrongChain(1)))
        #expect(await RPCEndpoints.validate("https://node.example.com", chainID: 1) { _ in throw Down() } == .failure(.unreachable))
        // 写法不对时根本不发请求
        #expect(await RPCEndpoints.validate("http://node.example.com", chainID: 1) { _ in Issue.record("called"); return 1 } == .failure(.notHTTPS))
    }

    @Test func masksTheSecretPart() {
        let url = URL(string: "https://eth-mainnet.g.example.com/v2/AbCdEfGhIjKlMnOpQrSt")!
        let m = RPCEndpoints.masked(url)
        #expect(m == "https://eth-mainnet.g.example.com/v2/••••QrSt")
        #expect(!m.contains("EfGhIjKl"))
        #expect(RPCEndpoints.masked(URL(string: "http://localhost:8545")!) == "http://localhost:8545")
    }

    @Test func roundTripsAndFallsBackToDefaults() throws {
        var e = RPCEndpoints()
        #expect(e.url(chainID: 11_155_111) == EthRPC.defaultURL(chainID: 11_155_111))
        e.set(URL(string: "https://my-node.example.com/key")!, chainID: 11_155_111)
        #expect(e.url(chainID: 11_155_111)?.host == "my-node.example.com")
        #expect(e.url(chainID: 1) == EthRPC.defaultURL(chainID: 1))
        #expect(try RPCEndpoints(decoding: e.encoded()) == e)
        e.set(nil, chainID: 11_155_111)
        #expect(e.url(chainID: 11_155_111) == EthRPC.defaultURL(chainID: 11_155_111))
    }

    @Test func keychainNamesFollowTheBundleID() {
        #expect(KeychainNamespace.service("submitter-account", bundleID: "xyz.unipass.coordinator") == "xyz.unipass.coordinator.submitter-account")
        #expect(KeychainNamespace.service("submitter-account", bundleID: "xyz.unipass.demo.coordinator") == "xyz.unipass.demo.coordinator.submitter-account")
        #expect(KeychainNamespace.service("safe-api-key", bundleID: nil) == "xyz.unipass.coordinator.safe-api-key")
    }
}
