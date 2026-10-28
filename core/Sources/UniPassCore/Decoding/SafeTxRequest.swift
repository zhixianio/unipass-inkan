import Foundation

/// 一笔待签的 Safe 交易：从 `eth-sign-request`（data-type 2）的 EIP-712 JSON 严格解析而来，
/// safeTxHash 由我们自己重算。
///
/// 只接受**一种**序列化（`canonicalJSON`）：紧凑、键顺序固定、uint256 用十进制字符串、
/// operation 和 chainId 用 JSON 整数、地址用 EIP-55、字节用小写十六进制。先按结构逐项校验，
/// 再要求重新序列化后逐字节相同——空白、键顺序、数字写法、重复键之类的歧义全部排除。
/// 格式见 docs/ur-types.md「SafeTx 的 EIP-712 JSON」。
public struct SafeTxRequest: Hashable, Sendable {
    public var chainID: UInt64
    public var safe: Address
    public var tx: SafeTx

    public init(chainID: UInt64, safe: Address, tx: SafeTx) {
        self.chainID = chainID
        self.safe = safe
        self.tx = tx
    }

    public var safeTxHash: Data { tx.hash(chainId: UInt256(chainID), safe: safe) }

    public enum ParseError: Error, Hashable, Sendable {
        case json(String)
        /// 结构对，但不是唯一的规范序列化。
        case nonCanonical
        case invalidStructure(String)
        case invalidField(String)
        /// 调用方附带的哈希和重算结果不一致。
        case hashMismatch
        case notTypedData
        case missingRequestID
        case chainIDMismatch
    }

    static let domainFields: [(String, String)] = [("chainId", "uint256"), ("verifyingContract", "address")]
    static let safeTxFields: [(String, String)] = [
        ("to", "address"), ("value", "uint256"), ("data", "bytes"), ("operation", "uint8"),
        ("safeTxGas", "uint256"), ("baseGas", "uint256"), ("gasPrice", "uint256"),
        ("gasToken", "address"), ("refundReceiver", "address"), ("nonce", "uint256"),
    ]

    /// `expectedHash` 是调用方另外拿到的 safeTxHash（如果有），必须和重算结果一致。
    public init(typedDataJSON data: Data, expectedHash: Data? = nil) throws {
        let json: StrictJSON
        do { json = try StrictJSON(parsing: data) } catch { throw ParseError.json("\(error)") }

        guard json.keys == ["types", "primaryType", "domain", "message"] else {
            throw ParseError.invalidStructure("top-level keys")
        }
        guard json["primaryType"]?.stringValue == "SafeTx" else { throw ParseError.invalidStructure("primaryType") }
        guard let types = json["types"], types.keys == ["EIP712Domain", "SafeTx"],
              Self.fields(types["EIP712Domain"]) == Self.domainFields.map({ [$0.0, $0.1] }),
              Self.fields(types["SafeTx"]) == Self.safeTxFields.map({ [$0.0, $0.1] })
        else { throw ParseError.invalidStructure("types") }

        guard let domain = json["domain"], domain.keys == ["chainId", "verifyingContract"] else {
            throw ParseError.invalidStructure("domain")
        }
        let chainID = try Self.jsonInteger(domain["chainId"], "chainId", max: UInt64.max)
        guard chainID > 0 else { throw ParseError.invalidField("chainId") }
        let safe = try Self.address(domain["verifyingContract"], "verifyingContract")

        guard let m = json["message"], m.keys == Self.safeTxFields.map(\.0) else {
            throw ParseError.invalidStructure("message")
        }
        let opRaw = try Self.jsonInteger(m["operation"], "operation", max: 1)
        let tx = SafeTx(
            to: try Self.address(m["to"], "to"),
            value: try Self.uint256(m["value"], "value"),
            data: try Self.bytes(m["data"], "data"),
            operation: SafeTx.Operation(rawValue: UInt8(opRaw))!,
            safeTxGas: try Self.uint256(m["safeTxGas"], "safeTxGas"),
            baseGas: try Self.uint256(m["baseGas"], "baseGas"),
            gasPrice: try Self.uint256(m["gasPrice"], "gasPrice"),
            gasToken: try Self.address(m["gasToken"], "gasToken"),
            refundReceiver: try Self.address(m["refundReceiver"], "refundReceiver"),
            nonce: try Self.uint256(m["nonce"], "nonce")
        )
        self.init(chainID: chainID, safe: safe, tx: tx)

        guard Data(canonicalJSON.utf8) == data else { throw ParseError.nonCanonical }
        if let expectedHash, expectedHash != safeTxHash { throw ParseError.hashMismatch }
    }

    /// 唯一接受的序列化。Coordinator 用它生成请求。
    public var canonicalJSON: String {
        func fieldList(_ f: [(String, String)]) -> String {
            "[" + f.map { "{\"name\":\"\($0.0)\",\"type\":\"\($0.1)\"}" }.joined(separator: ",") + "]"
        }
        let types = "{\"EIP712Domain\":\(fieldList(Self.domainFields)),\"SafeTx\":\(fieldList(Self.safeTxFields))}"
        let domain = "{\"chainId\":\(chainID),\"verifyingContract\":\"\(safe.checksummed)\"}"
        let message = [
            "\"to\":\"\(tx.to.checksummed)\"",
            "\"value\":\"\(tx.value)\"",
            "\"data\":\"\(tx.data.hexString)\"",
            "\"operation\":\(tx.operation.rawValue)",
            "\"safeTxGas\":\"\(tx.safeTxGas)\"",
            "\"baseGas\":\"\(tx.baseGas)\"",
            "\"gasPrice\":\"\(tx.gasPrice)\"",
            "\"gasToken\":\"\(tx.gasToken.checksummed)\"",
            "\"refundReceiver\":\"\(tx.refundReceiver.checksummed)\"",
            "\"nonce\":\"\(tx.nonce)\"",
        ].joined(separator: ",")
        return "{\"types\":\(types),\"primaryType\":\"SafeTx\",\"domain\":\(domain),\"message\":{\(message)}}"
    }

    // MARK: - 字段

    private static func fields(_ j: StrictJSON?) -> [[String]]? {
        j?.arrayValue?.map { f in
            guard f.keys == ["name", "type"], let n = f["name"]?.stringValue, let t = f["type"]?.stringValue else { return [] }
            return [n, t]
        }
    }

    private static func jsonInteger(_ j: StrictJSON?, _ name: String, max: UInt64) throws -> UInt64 {
        guard let s = j?.numberValue, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              s == "0" || !s.hasPrefix("0"), let n = UInt64(s), n <= max
        else { throw ParseError.invalidField(name) }
        return n
    }

    /// uint256：十进制字符串，无前导零。
    private static func uint256(_ j: StrictJSON?, _ name: String) throws -> UInt256 {
        guard let s = j?.stringValue, s.count <= 78, s == "0" || !s.hasPrefix("0"),
              let n = UInt256(decimal: s) else { throw ParseError.invalidField(name) }
        return n
    }

    /// 地址：EIP-55 校验和格式（规范化检查在最后的逐字节比较里完成）。
    private static func address(_ j: StrictJSON?, _ name: String) throws -> Address {
        guard let s = j?.stringValue, s.hasPrefix("0x"), s.count == 42, let a = Address(hex: s) else {
            throw ParseError.invalidField(name)
        }
        return a
    }

    private static func bytes(_ j: StrictJSON?, _ name: String) throws -> Data {
        guard let s = j?.stringValue, s.hasPrefix("0x"), s.count % 2 == 0, let d = Data(hex: s) else {
            throw ParseError.invalidField(name)
        }
        return d
    }
}

extension SafeTxRequest {
    /// 从发给 Signer 的 `eth-sign-request` 取出 SafeTx（约定见 docs/ur-types.md「发给我们自己 Signer 的请求」）：
    /// data-type 必须是 2（EIP-712），必须带 request-id，带了 chain-id 就必须和 domain 一致。
    /// derivation-path、address 是否指向这台 Signer 由 Signer 自己核对（它才有自己的公钥）。
    public init(signRequest req: EthSignRequest) throws {
        guard req.dataType == .typedData else { throw ParseError.notTypedData }
        guard req.requestID != nil else { throw ParseError.missingRequestID }
        try self.init(typedDataJSON: req.signData)
        if let c = req.chainID, c != chainID { throw ParseError.chainIDMismatch }
    }
}
