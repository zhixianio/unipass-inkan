import Foundation
import Testing
@testable import UniPassCore

/// testvectors/decoding.json 由 viem 生成（testvectors/generator）。
struct DecodingVectors: Decodable {
    struct Call: Decodable { let signature: String; let to: String; let args: [Arg]; let calldata: String }
    struct Tx: Decodable { let operation: UInt8; let to, value, data: String }
    struct MultiSend: Decodable { let multiSend, calldata: String; let txs: [Tx] }
    struct Typed: Decodable { let json, safeTxHash: String }
    /// 参数：地址 / 十进制整数 / 十六进制字节都是字符串，bool 是 bool。
    enum Arg: Decodable {
        case string(String)
        case bool(Bool)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .string(try c.decode(String.self)) }
        }
        var s: String { if case .string(let s) = self { s } else { "" } }
        var addr: Address { Address(hex: s)! }
        var uint: UInt256 { UInt256(decimal: s)! }
        var bytes: Data { Data(hex: s)! }
        var bool: Bool { if case .bool(let b) = self { b } else { false } }
    }
    let calls: [Call]
    let multiSends: [MultiSend]
    let typedData: [Typed]

    static let shared = try! loadVectors(DecodingVectors.self, "decoding.json")
}

struct SafeTxRequestTests {
    let v = DecodingVectors.shared

    @Test func viemTypedDataRoundTrip() throws {
        for t in v.typedData {
            let req = try SafeTxRequest(typedDataJSON: Data(t.json.utf8), expectedHash: Data(hex: t.safeTxHash)!)
            #expect(req.canonicalJSON == t.json)
            #expect(req.safeTxHash.hexString == t.safeTxHash)
        }
    }

    static func mutate(_ json: String, _ from: String, _ to: String) -> Data {
        precondition(json.contains(from), from)
        return Data(json.replacingOccurrences(of: from, with: to).utf8)
    }

    @Test func rejectsEverythingButCanonical() throws {
        let base = v.typedData[0].json
        let req = try SafeTxRequest(typedDataJSON: Data(base.utf8))
        let to = req.tx.to.checksummed
        let cases: [(Data, SafeTxRequest.ParseError)] = [
            (Data((" " + base).utf8), .nonCanonical),
            (Self.mutate(base, "\"primaryType\":\"SafeTx\",", ""), .invalidStructure("top-level keys")),
            (Self.mutate(base, "\"primaryType\":\"SafeTx\"", "\"primaryType\":\"Other\""), .invalidStructure("primaryType")),
            (Self.mutate(base, "{\"name\":\"chainId\",\"type\":\"uint256\"},", ""), .invalidStructure("types")),
            (Self.mutate(base, "{\"name\":\"nonce\",\"type\":\"uint256\"}", "{\"name\":\"nonce\",\"type\":\"uint128\"}"), .invalidStructure("types")),
            (Self.mutate(base, "\"domain\":{", "\"domain\":{\"name\":\"Safe\","), .invalidStructure("domain")),
            (Self.mutate(base, "\"chainId\":\(req.chainID)", "\"chainId\":\"\(req.chainID)\""), .invalidField("chainId")),
            (Self.mutate(base, "\"chainId\":\(req.chainID)", "\"chainId\":0"), .invalidField("chainId")),
            (Self.mutate(base, "\"chainId\":\(req.chainID)", "\"chainId\":\(req.chainID).0"), .invalidField("chainId")),
            (Self.mutate(base, "\"to\":\"\(to)\"", "\"to\":\"\(to.lowercased())\""), .nonCanonical),
            (Self.mutate(base, "\"to\":\"\(to)\"", "\"to\":\"\(to.dropLast())\""), .invalidField("to")),
            (Self.mutate(base, "\"operation\":\(req.tx.operation.rawValue)", "\"operation\":2"), .invalidField("operation")),
            (Self.mutate(base, "\"nonce\":\"\(req.tx.nonce)\"", "\"nonce\":\(req.tx.nonce)"), .invalidField("nonce")),
            (Self.mutate(base, "\"nonce\":\"\(req.tx.nonce)\"", "\"nonce\":\"0\(req.tx.nonce)\""), .invalidField("nonce")),
            (Self.mutate(base, "\"nonce\":\"\(req.tx.nonce)\"", "\"nonce\":\"\(String(repeating: "9", count: 78))\""), .invalidField("nonce")),
            (Self.mutate(base, "\"nonce\":\"\(req.tx.nonce)\"", "\"nonce\":\"\(req.tx.nonce)\",\"extra\":\"1\""), .invalidStructure("message")),
            (Self.mutate(base, "\"data\":\"0x", "\"data\":\"0x0"), .invalidField("data")),
        ]
        for (data, error) in cases {
            #expect(throws: error, "\(String(decoding: data, as: UTF8.self).prefix(0))") { try SafeTxRequest(typedDataJSON: data) }
        }
        // 重复键、截断、非 ASCII、转义都在 JSON 层拒绝。
        for bad in [Self.mutate(base, "\"primaryType\":\"SafeTx\"", "\"primaryType\":\"SafeTx\",\"primaryType\":\"SafeTx\""),
                    Data(base.utf8.dropLast()), Self.mutate(base, "SafeTx\"", "SafeTx\\u0000\""),
                    Self.mutate(base, "\"primaryType\"", "\"primaryType\u{00e9}\"")] {
            #expect(throws: SafeTxRequest.ParseError.self) { try SafeTxRequest(typedDataJSON: bad) }
        }
        #expect(throws: SafeTxRequest.ParseError.hashMismatch) {
            try SafeTxRequest(typedDataJSON: Data(base.utf8), expectedHash: Data(count: 32))
        }
    }

    @Test func fromSignRequest() throws {
        let json = Data(v.typedData[1].json.utf8)
        let req = try SafeTxRequest(typedDataJSON: json)
        let kp = CryptoKeypath(components: [], sourceFingerprint: 7)
        func sr(_ dt: EthSignRequest.DataType = .typedData, id: Data? = Data(count: 16), chain: UInt64?) -> EthSignRequest {
            EthSignRequest(requestID: id, signData: json, dataType: dt, chainID: chain, derivationPath: kp)
        }
        #expect(try SafeTxRequest(signRequest: sr(chain: req.chainID)) == req)
        #expect(try SafeTxRequest(signRequest: sr(chain: nil)) == req)
        #expect(throws: SafeTxRequest.ParseError.chainIDMismatch) { try SafeTxRequest(signRequest: sr(chain: req.chainID + 1)) }
        #expect(throws: SafeTxRequest.ParseError.notTypedData) { try SafeTxRequest(signRequest: sr(.personalMessage, chain: nil)) }
        #expect(throws: SafeTxRequest.ParseError.missingRequestID) { try SafeTxRequest(signRequest: sr(id: nil, chain: nil)) }
        // 经过 UR 往返也一样。
        let ur = try UR(parsing: sr(chain: req.chainID).ur.qrString)
        #expect(try SafeTxRequest(signRequest: EthSignRequest(ur: ur)) == req)
    }

    @Test func fuzzJSON() {
        var rng = SplitMix64(seed: 0x4A50_4E)
        let base = Array(v.typedData[2].json.utf8)
        let alphabet = Array("{}[]\",:0x".utf8)
        for _ in 0..<5000 {
            var b = base
            for _ in 0..<(1 + rng.next() % 3) {
                let i = Int(rng.next() % UInt64(b.count))
                switch rng.next() % 3 {
                case 0: b[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: b.remove(at: i)
                default: b.insert(alphabet[Int(rng.next() % UInt64(alphabet.count))], at: i)
                }
            }
            if let r = try? SafeTxRequest(typedDataJSON: Data(b)) {
                // 能通过的只能是规范序列化本身。
                #expect(Array(r.canonicalJSON.utf8) == b)
            }
        }
    }
}

struct CallDecoderTests {
    let v = DecodingVectors.shared
    static let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
    static let decoder = CallDecoder(chainID: 11_155_111, safe: safe)

    static func expected(_ c: DecodingVectors.Call) -> KnownCall {
        let a = c.args
        switch c.signature {
        case "transfer(address,uint256)": return .erc20Transfer(to: a[0].addr, amount: a[1].uint)
        case "transferFrom(address,address,uint256)": return .transferFrom(from: a[0].addr, to: a[1].addr, amountOrTokenID: a[2].uint)
        case "approve(address,uint256)": return .erc20Approve(spender: a[0].addr, amount: a[1].uint)
        case "increaseAllowance(address,uint256)": return .increaseAllowance(spender: a[0].addr, addedValue: a[1].uint)
        case "decreaseAllowance(address,uint256)": return .decreaseAllowance(spender: a[0].addr, subtractedValue: a[1].uint)
        case "setApprovalForAll(address,bool)": return .setApprovalForAll(operator: a[0].addr, approved: a[1].bool)
        case "safeTransferFrom(address,address,uint256)": return .erc721SafeTransferFrom(from: a[0].addr, to: a[1].addr, tokenID: a[2].uint, data: nil)
        case "safeTransferFrom(address,address,uint256,bytes)":
            return .erc721SafeTransferFrom(from: a[0].addr, to: a[1].addr, tokenID: a[2].uint, data: a[3].bytes)
        case "safeTransferFrom(address,address,uint256,uint256,bytes)":
            return .erc1155SafeTransferFrom(from: a[0].addr, to: a[1].addr, id: a[2].uint, amount: a[3].uint, data: a[4].bytes)
        case "approve(address,address,uint160,uint48)":
            return .permit2Approve(token: a[0].addr, spender: a[1].addr, amount: a[2].uint, expiration: UInt64(a[3].s)!)
        case "addOwnerWithThreshold(address,uint256)": return .addOwnerWithThreshold(owner: a[0].addr, threshold: a[1].uint)
        case "removeOwner(address,address,uint256)": return .removeOwner(prevOwner: a[0].addr, owner: a[1].addr, threshold: a[2].uint)
        case "swapOwner(address,address,address)": return .swapOwner(prevOwner: a[0].addr, oldOwner: a[1].addr, newOwner: a[2].addr)
        case "changeThreshold(uint256)": return .changeThreshold(a[0].uint)
        case "enableModule(address)": return .enableModule(a[0].addr)
        case "disableModule(address,address)": return .disableModule(prevModule: a[0].addr, module: a[1].addr)
        case "setGuard(address)": return .setGuard(a[0].addr)
        case "setModuleGuard(address)": return .setModuleGuard(a[0].addr)
        case "setFallbackHandler(address)": return .setFallbackHandler(a[0].addr)
        default: fatalError(c.signature)
        }
    }

    @Test func viemCalldata() {
        #expect(Set(v.calls.map(\.signature)).count == 19)
        for c in v.calls {
            let call = Self.decoder.decode(operation: .call, to: Address(hex: c.to)!, value: .zero, data: Data(hex: c.calldata)!)
            #expect(call.action == .known(Self.expected(c)), "\(c.signature)")
        }
    }

    @Test func scopedFunctions() {
        let other = Address(hex: "0x0000000000000000000000000000000000001234")!
        for c in v.calls where ["changeThreshold(uint256)", "approve(address,address,uint160,uint48)"].contains(c.signature) {
            // Safe 自身的函数只在 to == Safe 时识别；Permit2 只在规范地址上识别。
            let call = Self.decoder.decode(operation: .call, to: other, value: .zero, data: Data(hex: c.calldata)!)
            #expect(call.action == .unknown(selector: Data(hex: c.calldata)!.prefix(4)))
        }
    }

    @Test func nonCanonicalArgumentsRejected() {
        let token = Address(hex: "0x0000000000000000000000000000000000001234")!
        let transfer = Data(hex: "0xa9059cbb")!
        let word = { (hex: String) in Data(hex: String(repeating: "0", count: 64 - hex.count) + hex)! }
        let cases: [(Data, String)] = [
            (transfer + word("1" + String(repeating: "0", count: 40)) + word("05"), "transfer(address,uint256)"), // 地址高位不为 0
            (transfer + word("01") + word("05") + word("00"), "transfer(address,uint256)"), // 多余字节
            (transfer + word("01") + Data(hex: "05")!, "transfer(address,uint256)"), // 截断
            (Data(hex: "0xa22cb465")! + word("01") + word("02"), "setApprovalForAll(address,bool)"), // bool = 2
            (Data(hex: "0xb88d4fde")! + word("01") + word("02") + word("03") + word("a0") + word("00"), "safeTransferFrom(address,address,uint256,bytes)"), // 非标准偏移
        ]
        for (data, sig) in cases {
            let call = Self.decoder.decode(operation: .call, to: token, value: .zero, data: data)
            #expect(call.action == .invalid(.malformedArguments(sig)), "\(data.hexString)")
        }
        // Permit2 的 uint160 / uint48 超宽。
        let permit = Data(hex: "0x87517c45")! + word("01") + word("02") + word("1" + String(repeating: "0", count: 40)) + word("03")
        #expect(Self.decoder.decode(operation: .call, to: SafeDeployments.permit2, value: .zero, data: permit).action
            == .invalid(.malformedArguments("approve(address,address,uint160,uint48)")))
        // 不足 4 字节、不认识的选择器。
        #expect(Self.decoder.decode(operation: .call, to: token, value: .zero, data: Data([1, 2])).action == .unknown(selector: nil))
        #expect(Self.decoder.decode(operation: .call, to: token, value: .zero, data: Data(hex: "0xdeadbeef")!).action
            == .unknown(selector: Data(hex: "0xdeadbeef")!))
    }

    @Test func viemMultiSend() {
        for m in v.multiSends {
            let call = Self.decoder.decode(operation: .delegateCall, to: Address(hex: m.multiSend)!, value: .zero, data: Data(hex: m.calldata)!)
            guard case .multiSend(let contract, let inner) = call.action else {
                Issue.record("not decoded as multiSend: \(call.action)")
                continue
            }
            #expect(contract.version == "1.4.1" && contract.kind == .multiSend)
            #expect(inner.map { [String($0.operation.rawValue), $0.to.checksummed, $0.value.description, $0.data.hexString] }
                == m.txs.map { [String($0.operation), Address(hex: $0.to)!.checksummed, $0.value, $0.data] })
            #expect(call.problems.isEmpty)
        }
        // 最后一个用例里有一层嵌套：内层是前 min(2, n) 条交易（n 不含嵌套那一条）。
        let n = v.multiSends[5].txs.count - 1
        let nested = Self.decoder.decode(operation: .delegateCall, to: Address(hex: v.multiSends[5].multiSend)!, value: .zero,
                                         data: Data(hex: v.multiSends[5].calldata)!)
        #expect(nested.flattened.count == 1 + v.multiSends[5].txs.count + min(2, n))
    }

    static func pack(_ txs: [(UInt8, Address, Data)]) -> Data {
        let packed = txs.reduce(Data()) { acc, t in
            acc + Data([t.0]) + t.1.bytes + UInt256.zero.bigEndianBytes + UInt256(UInt64(t.2.count)).bigEndianBytes + t.2
        }
        return Selectors.multiSend + ABICodec.encode([.bytes], [.bytes(packed)])!
    }

    @Test func multiSendProblems() {
        let a = Address(hex: "0x00000000000000000000000000000000000000aa")!
        let ms141 = Address(hex: "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526")!
        let callOnly141 = Address(hex: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2")!
        let one = Self.pack([(0, a, Data())])
        func action(_ op: SafeTx.Operation, _ to: Address, _ data: Data, chain: UInt64 = 11_155_111) -> CallAction {
            CallDecoder(chainID: chain, safe: Self.safe).decode(operation: op, to: to, value: .zero, data: data).action
        }
        #expect(action(.call, ms141, one) == .invalid(.multiSendViaCall))
        #expect(action(.call, callOnly141, one) == .invalid(.multiSendViaCall))
        #expect(action(.delegateCall, callOnly141, Self.pack([(1, a, Data())])) == .invalid(.delegateCallInCallOnly))
        #expect(action(.delegateCall, ms141, Self.pack([(2, a, Data())])) == .invalid(.invalidInnerOperation(2)))
        // 打包数据截断：把 dataLength 改大。
        var truncated = Data([0]) + a.bytes + UInt256.zero.bigEndianBytes + UInt256(5).bigEndianBytes + Data([1, 2])
        #expect(action(.delegateCall, ms141, Selectors.multiSend + ABICodec.encode([.bytes], [.bytes(truncated)])!) == .invalid(.malformedMultiSend))
        truncated = Data([0]) + a.bytes
        #expect(action(.delegateCall, ms141, Selectors.multiSend + ABICodec.encode([.bytes], [.bytes(truncated)])!) == .invalid(.malformedMultiSend))
        // 不支持的链上不认 MultiSend。
        #expect(action(.delegateCall, ms141, one, chain: 10) == .unknown(selector: Selectors.multiSend))
        // 嵌套过深。
        var data = one
        for _ in 0..<3 { data = Self.pack([(1, ms141, data)]) }
        let deep = CallDecoder(chainID: 1, safe: Self.safe).decode(operation: .delegateCall, to: ms141, value: .zero, data: data)
        #expect(deep.problems == [.nestingTooDeep])
        // 调用总数上限。
        var limits = CallDecoder.Limits()
        limits.maxCalls = 3
        let many = CallDecoder(chainID: 1, safe: Self.safe, limits: limits)
            .decode(operation: .delegateCall, to: ms141, value: .zero, data: Self.pack(Array(repeating: (0, a, Data()), count: 4)))
        #expect(many.action == .invalid(.tooManyCalls))
    }

    @Test func zeroAddressMeansSafeOnlyIn150() throws {
        let addOwner = Selectors.byID.values.first { $0.signature.hasPrefix("addOwnerWithThreshold") }!.selector
            + ABICodec.encode([.address, .uint(256)], [.address(Address(hex: "0x00000000000000000000000000000000000000bb")!), .uint(UInt256(2))])!
        let data = Self.pack([(0, .zero, addOwner)])
        let v150 = Self.decoder.decode(operation: .delegateCall, to: Address(hex: "0x218543288004CD07832472D464648173c77D7eB7")!, value: .zero, data: data)
        guard case .multiSend(_, let inner150) = v150.action else { Issue.record("1.5.0"); return }
        #expect(inner150[0].to == Self.safe && inner150[0].rawTo == .zero)
        #expect(inner150[0].action == .known(.addOwnerWithThreshold(owner: Address(hex: "0x00000000000000000000000000000000000000bb")!, threshold: UInt256(2))))
        let v141 = Self.decoder.decode(operation: .delegateCall, to: Address(hex: "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526")!, value: .zero, data: data)
        guard case .multiSend(_, let inner141) = v141.action else { Issue.record("1.4.1"); return }
        #expect(inner141[0].to == .zero)
        #expect(inner141[0].action == .unknown(selector: addOwner.prefix(4)))
    }

    @Test func allMultiSendAddressesRecognisedOnSupportedChains() {
        for chain in SafeDeployments.supportedChains {
            for c in SafeDeployments.multiSendContracts {
                #expect(SafeDeployments.multiSend(chainID: chain, address: c.address) == c)
            }
        }
        #expect(SafeDeployments.multiSendContracts.count == 8)
    }

    @Test func fuzzCallDecoder() {
        var rng = SplitMix64(seed: 0xDEC0DE)
        let seeds = v.multiSends.map { Data(hex: $0.calldata)! } + v.calls.map { Data(hex: $0.calldata)! }
        let targets = SafeDeployments.multiSendContracts.map(\.address) + [Self.safe, SafeDeployments.permit2]
        for _ in 0..<3000 {
            var d = seeds[Int(rng.next() % UInt64(seeds.count))]
            for _ in 0..<(1 + rng.next() % 4) where !d.isEmpty {
                let i = Int(rng.next() % UInt64(d.count))
                switch rng.next() % 3 {
                case 0: d[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: d.removeSubrange(i..<min(d.count, i + Int(rng.next() % 40)))
                default: d.insert(contentsOf: Data((0..<Int(rng.next() % 40)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }), at: i)
                }
            }
            let call = Self.decoder.decode(operation: rng.next() % 2 == 0 ? .call : .delegateCall,
                                           to: targets[Int(rng.next() % UInt64(targets.count))], value: .zero, data: d)
            #expect(call.flattened.count <= CallDecoder.Limits().maxCalls + 1)
        }
    }
}

struct DecodedSafeTxTests {
    /// 从 eth-sign-request 一路解到 MultiSend 里的每一条调用。
    @Test func endToEnd() throws {
        let safe = CallDecoderTests.safe
        let owner = Address(hex: "0x00000000000000000000000000000000000000bb")!
        let token = Address(hex: "0x00000000000000000000000000000000000000cc")!
        let addOwner = Selectors.byID.values.first { $0.signature.hasPrefix("addOwnerWithThreshold") }!.selector
            + ABICodec.encode([.address, .uint(256)], [.address(owner), .uint(UInt256(2))])!
        let transfer = Data(Keccak.hash256(Data("transfer(address,uint256)".utf8)).prefix(4))
            + ABICodec.encode([.address, .uint(256)], [.address(owner), .uint(UInt256(1000))])!
        let tx = SafeTx(to: Address(hex: "0x218543288004CD07832472D464648173c77D7eB7")!, data: CallDecoderTests.pack([(0, .zero, addOwner), (0, token, transfer)]),
                        operation: .delegateCall, nonce: UInt256(7))
        let req = SafeTxRequest(chainID: 8453, safe: safe, tx: tx)
        let sign = EthSignRequest(requestID: Data(count: 16), signData: Data(req.canonicalJSON.utf8), dataType: .typedData,
                                  chainID: 8453, derivationPath: CryptoKeypath(components: [], sourceFingerprint: 1))
        let parsed = try SafeTxRequest(signRequest: EthSignRequest(ur: UR(parsing: sign.ur.qrString)))
        let decoded = DecodedSafeTx(parsed)
        #expect(decoded.request.safeTxHash == req.safeTxHash)
        #expect(decoded.call.problems.isEmpty)
        #expect(decoded.call.flattened.map(\.action).dropFirst() == [
            .known(.addOwnerWithThreshold(owner: owner, threshold: UInt256(2))),
            .known(.erc20Transfer(to: owner, amount: UInt256(1000))),
        ])
        #expect(decoded.call.flattened[1].to == safe)
    }
}
