import Foundation
import UniPassCore

/// 最小的以太坊 JSON-RPC 客户端：只读调用、广播已签名交易。这里不签交易，签名在 SubmitterAccount 包里。
public struct EthRPC: Sendable {
    public let url: URL
    private let session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    /// 开发期默认用公共节点；正式版让用户填自己的。
    public static func defaultURL(chainID: UInt64) -> URL? {
        switch chainID {
        case 11_155_111: URL(string: "https://ethereum-sepolia-rpc.publicnode.com")
        case 1: URL(string: "https://ethereum-rpc.publicnode.com")
        case 8453: URL(string: "https://base-rpc.publicnode.com")
        default: nil
        }
    }

    public enum RPCError: Error, Equatable, Sendable {
        case http(Int)
        case rpc(code: Int, message: String)
        case invalidResponse
    }

    public func chainID() async throws -> UInt64 {
        let hex: String = try await request("eth_chainId", [])
        guard let n = UInt256(hex: hex), n.words[1...].allSatisfy({ $0 == 0 }) else { throw RPCError.invalidResponse }
        return n.words[0]
    }

    public func call(to: Address, data: Data) async throws -> Data {
        let hex: String = try await request("eth_call", [
            .object(["to": to.checksummed, "data": data.hexString]), .string("latest"),
        ])
        guard let d = Data(hex: hex) else { throw RPCError.invalidResponse }
        return d
    }

    /// 广播外部钱包签好的交易，返回交易哈希。
    public func sendRawTransaction(_ raw: Data) async throws -> String {
        try await request("eth_sendRawTransaction", [.string(raw.hexString)])
    }

    // MARK: 余额、手续费、交易状态

    public func balance(of address: Address) async throws -> UInt256 {
        try Self.quantity(try await request("eth_getBalance", [.string(address.checksummed), .string("latest")]))
    }

    /// ERC-20 `balanceOf(owner)`。
    public func tokenBalance(token: Address, owner: Address) async throws -> UInt256 {
        let data = Self.selector("balanceOf(address)") + owner.abiEncoded
        return try Self.decodeUInt(try await call(to: token, data: data))
    }

    public func gasPrice() async throws -> UInt256 {
        try Self.quantity(try await request("eth_gasPrice", []))
    }

    public func maxPriorityFeePerGas() async throws -> UInt256 {
        try Self.quantity(try await request("eth_maxPriorityFeePerGas", []))
    }

    /// 最新区块的 baseFeePerGas。
    public func baseFee() async throws -> UInt256 {
        struct Block: Decodable { let baseFeePerGas: String? }
        let block: Block = try await request("eth_getBlockByNumber", [.string("latest"), .bool(false)])
        return try Self.quantity(block.baseFeePerGas ?? "0x0")
    }

    public func transactionCount(_ address: Address, block: String = "pending") async throws -> UInt64 {
        let n = try Self.quantity(try await request("eth_getTransactionCount", [.string(address.checksummed), .string(block)]))
        return n.words[0]
    }

    public func estimateGas(from: Address, to: Address, data: Data, value: UInt256 = .zero) async throws -> UInt256 {
        try Self.quantity(try await request("eth_estimateGas", [.object([
            "from": from.checksummed, "to": to.checksummed, "data": data.hexString, "value": Self.hexQuantity(value),
        ])]))
    }

    public struct Receipt: Decodable, Sendable {
        public let status: String?
        public let blockNumber: String?
        public let gasUsed: String?
        public var succeeded: Bool { status == "0x1" }
    }

    /// 还没上链时返回 nil。
    public func receipt(_ txHash: String) async throws -> Receipt? {
        try await requestOptional("eth_getTransactionReceipt", [.string(txHash)])
    }

    static func quantity(_ hex: String) throws -> UInt256 {
        guard let n = UInt256(hex: hex) else { throw RPCError.invalidResponse }
        return n
    }

    static func hexQuantity(_ n: UInt256) -> String {
        let d = n.bigEndianBytes.drop { $0 == 0 }
        let hex = d.map { String(format: "%02x", $0) }.joined()
        let trimmed = String(hex.drop { $0 == "0" })
        return "0x" + (trimmed.isEmpty ? "0" : trimmed)
    }

    // MARK: 合约读

    /// `SafeWebAuthnSignerFactory.getSigner(uint256 x, uint256 y, uint176 verifiers)`：配对时核对 Signer 给的 proxy 地址。
    public func webAuthnSigner(factory: Address, x: Data, y: Data, verifiers: Data) async throws -> Address {
        precondition(x.count == 32 && y.count == 32 && verifiers.count == 22)
        let data = Self.selector("getSigner(uint256,uint256,uint176)") + x + y + Data(count: 10) + verifiers
        return try Self.decodeAddress(try await call(to: factory, data: data))
    }

    /// 合约字节码（没有部署时是空的）。
    public func code(at address: Address) async throws -> Data {
        let hex: String = try await request("eth_getCode", [.string(address.checksummed), .string("latest")])
        guard let d = Data(hex: hex) else { throw RPCError.invalidResponse }
        return d
    }

    /// 存储槽里的 32 字节。
    public func storage(at address: Address, slot: Data) async throws -> Data {
        precondition(slot.count == 32)
        let hex: String = try await request("eth_getStorageAt", [.string(address.checksummed), .string(slot.hexString), .string("latest")])
        guard let d = Data(hex: hex), d.count == 32 else { throw RPCError.invalidResponse }
        return d
    }

    /// Safe 启用的 module（`getModulesPaginated(SENTINEL, 10)` 的第一页；添加已有 Safe 时只需要知道有没有）。
    public func safeModules(_ safe: Address) async throws -> [Address] {
        let sentinel = Address(bytes: Data(count: 19) + Data([1]))!
        let data = Self.selector("getModulesPaginated(address,uint256)") + sentinel.abiEncoded + UInt256(10).bigEndianBytes
        let out = try await call(to: safe, data: data)
        // 返回 (address[] array, address next)：第一个字是数组的偏移（64），第二个字是 next。
        guard out.count >= 96, UInt256(bigEndian: out.prefix(32)) == UInt256(64),
              let modules = ABICodec.decodeAddressArray(UInt256(32).bigEndianBytes + out.dropFirst(64)) else { throw RPCError.invalidResponse }
        return modules
    }

    public func safeNonce(_ safe: Address) async throws -> UInt256 {
        try Self.decodeUInt(try await call(to: safe, data: Self.selector("nonce()")))
    }

    public func safeThreshold(_ safe: Address) async throws -> UInt256 {
        try Self.decodeUInt(try await call(to: safe, data: Self.selector("getThreshold()")))
    }

    public func safeOwners(_ safe: Address) async throws -> [Address] {
        let out = try await call(to: safe, data: Self.selector("getOwners()"))
        guard let v = ABICodec.decodeAddressArray(out) else { throw RPCError.invalidResponse }
        return v
    }

    static func selector(_ signature: String) -> Data {
        Data(Keccak.hash256(Data(signature.utf8)).prefix(4))
    }

    static func decodeUInt(_ d: Data) throws -> UInt256 {
        guard d.count == 32, let n = UInt256(bigEndian: d) else { throw RPCError.invalidResponse }
        return n
    }

    static func decodeAddress(_ d: Data) throws -> Address {
        guard d.count == 32, d.prefix(12).allSatisfy({ $0 == 0 }), let a = Address(bytes: d.suffix(20)) else {
            throw RPCError.invalidResponse
        }
        return a
    }

    // MARK: JSON-RPC

    enum JSON: Encodable, Sendable {
        case string(String)
        case bool(Bool)
        case object([String: String])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .bool(let b): try c.encode(b)
            case .object(let o): try c.encode(o)
            }
        }
    }

    struct Request: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: [JSON]
    }

    struct Response<T: Decodable>: Decodable {
        struct ErrorBody: Decodable {
            let code: Int
            let message: String
        }

        let result: T?
        let error: ErrorBody?
    }

    func request<T: Decodable>(_ method: String, _ params: [JSON]) async throws -> T {
        guard let result: T = try await requestOptional(method, params) else { throw RPCError.invalidResponse }
        return result
    }

    /// `result` 为 null 时返回 nil（例如还没上链的交易回执）。
    func requestOptional<T: Decodable>(_ method: String, _ params: [JSON]) async throws -> T? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(method: method, params: params))
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RPCError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RPCError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(Response<T>.self, from: data)
        if let e = decoded.error { throw RPCError.rpc(code: e.code, message: e.message) }
        return decoded.result
    }
}

extension ABICodec {
    /// `address[]` 的返回值（`getOwners()`）。
    static func decodeAddressArray(_ d: Data) -> [Address]? {
        let b = [UInt8](d)
        guard b.count >= 64, let offset = UInt256(bigEndian: Data(b[0..<32])), offset == UInt256(32),
              let n = UInt256(bigEndian: Data(b[32..<64])), n.words[1...].allSatisfy({ $0 == 0 }), n.words[0] <= 1000,
              b.count == 64 + 32 * Int(n.words[0])
        else { return nil }
        return (0..<Int(n.words[0])).compactMap { i -> Address? in
            let w = Data(b[(64 + 32 * i)..<(96 + 32 * i)])
            return w.prefix(12).allSatisfy({ $0 == 0 }) ? Address(bytes: w.suffix(20)) : nil
        }
    }
}
