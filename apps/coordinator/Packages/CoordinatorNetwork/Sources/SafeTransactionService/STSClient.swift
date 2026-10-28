import Foundation
import UniPassCore

/// Safe Transaction Service 的最小客户端。
///
/// - 托管版需要 API key（`Authorization: Bearer <JWT>`）。不带 key 也能调，但限 2 RPS、每月 5,000 次，
///   只适合探索（docs.safe.global/core-api/how-to-use-api-keys）；不带 key 时客户端自己把请求间隔拉到 0.55 s。
/// - 路径里的地址必须是 EIP-55 校验和格式，否则 STS 返回 422 "Checksum address validation failed"。
/// - 客户端不信任 STS 返回的 safeTxHash：发提案时自己用 core 算 `contractTransactionHash`。
public struct STSClient: Sendable {
    public let chain: SafeChain
    public let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let throttle: Throttle

    public init(chain: SafeChain, apiKey: String?, baseURL: URL? = nil, session: URLSession = .shared) {
        self.chain = chain
        self.baseURL = baseURL ?? chain.hostedBaseURL
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
        throttle = Throttle(minimumInterval: self.apiKey == nil ? 0.55 : 0)
    }

    public var hasAPIKey: Bool { apiKey != nil }

    // MARK: 只读

    public func about() async throws -> STSAbout {
        try await get("api/v1/about/")
    }

    public func safeInfo(_ safe: Address) async throws -> SafeInfo {
        try await get("api/v1/safes/\(safe.checksummed)/")
    }

    /// Safe 是怎么创建的：factory、singleton、setup 调用数据、saltNonce（添加已有 Safe 时用来重算地址）。
    /// 不是通过 SafeProxyFactory 创建的 Safe，交易服务给不出这些，返回 404 或缺字段。
    public func safeCreation(_ safe: Address) async throws -> SafeCreationInfo {
        try await get("api/v1/safes/\(safe.checksummed)/creation/")
    }

    /// 按 nonce 倒序。`executed == false` 即待签队列。
    public func multisigTransactions(
        _ safe: Address, executed: Bool? = nil, limit: Int = 20
    ) async throws -> STSPage<MultisigTransaction> {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "ordering", value: "-nonce")]
        if let executed { query.append(URLQueryItem(name: "executed", value: executed ? "true" : "false")) }
        return try await get("api/v2/safes/\(safe.checksummed)/multisig-transactions/", query: query)
    }

    public func multisigTransaction(safeTxHash: Data) async throws -> MultisigTransaction {
        try await get("api/v2/multisig-transactions/\(safeTxHash.hexString)/")
    }

    // MARK: 写入（等 contracts/ 部署出测试 Safe 后实测）

    /// 发起提案，同时附上 `sender` 的签名。
    ///
    /// `sender` 必须是 owner 或 delegate；`signature` 是 sender 自己的那一份，
    /// 合约 owner 用 `STSSignature.contract(owner:signature:)` 包装。
    /// 返回本地算出的 safeTxHash。
    @discardableResult
    public func propose(
        safe: Address, transaction tx: SafeTx, sender: Address, signature: Data, origin: String? = nil
    ) async throws -> Data {
        let safeTxHash = tx.hash(chainId: UInt256(chain.chainId), safe: safe)
        let body = ProposeBody(
            safe: safe.checksummed,
            to: tx.to.checksummed,
            value: tx.value.description,
            data: tx.data.isEmpty ? nil : tx.data.hexString,
            operation: Int(tx.operation.rawValue),
            gasToken: tx.gasToken.checksummed,
            safeTxGas: tx.safeTxGas.description,
            baseGas: tx.baseGas.description,
            gasPrice: tx.gasPrice.description,
            refundReceiver: tx.refundReceiver.checksummed,
            nonce: tx.nonce.description,
            contractTransactionHash: safeTxHash.hexString,
            sender: sender.checksummed,
            signature: signature.hexString,
            origin: origin
        )
        try await send("api/v2/safes/\(safe.checksummed)/multisig-transactions/", body: body)
        return safeTxHash
    }

    /// 给已有提案追加一个 owner 的签名（格式同 `propose` 的 `signature`）。
    public func confirm(safeTxHash: Data, signature: Data) async throws {
        try await send("api/v1/multisig-transactions/\(safeTxHash.hexString)/confirmations/", body: ConfirmationBody(signature: signature.hexString))
    }

    /// 提交一个 owner 的签名：STS 里还没有这笔交易就以这个 owner 为 sender 发起提案（合约 owner 也可以），
    /// 已经有了就追加确认。返回 true 表示发起了新提案。
    @discardableResult
    public func submit(_ signature: SafeOwnerSignature, safe: Address, transaction tx: SafeTx, origin: String? = nil) async throws -> Bool {
        let encoded: Data = switch signature {
        case .eoa(_, let sig): sig
        case .contract(let owner, let sig): STSSignature.contract(owner: owner, signature: sig)
        }
        let safeTxHash = tx.hash(chainId: UInt256(chain.chainId), safe: safe)
        do {
            _ = try await multisigTransaction(safeTxHash: safeTxHash)
        } catch STSError.http(status: 404, body: _) {
            try await propose(safe: safe, transaction: tx, sender: signature.owner, signature: encoded, origin: origin)
            return true
        }
        try await confirm(safeTxHash: safeTxHash, signature: encoded)
        return false
    }

    // MARK: HTTP

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(request(path, query: query))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, body: some Encodable) async throws {
        var request = request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        await throttle.wait()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw STSError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw STSError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

/// 两次请求之间至少间隔 `minimumInterval` 秒。
actor Throttle {
    private let minimumInterval: TimeInterval
    private var next = ContinuousClock.now

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func wait() async {
        guard minimumInterval > 0 else { return }
        let now = ContinuousClock.now
        let start = max(now, next)
        next = start + .milliseconds(Int(minimumInterval * 1000))
        if start > now { try? await Task.sleep(until: start) }
    }
}

/// STS 接受的签名格式：一个 owner 的、Safe `signatures` 格式的完整字节。
public enum STSSignature {
    /// 合约 owner（EIP-1271，例如 `SafeWebAuthnSignerProxy`）。STS 记为 `CONTRACT_SIGNATURE`。
    ///
    /// 字节布局（共 65 + 32 + n 字节）：
    /// `r = owner 地址（左补零到 32 字节）‖ s = 65（动态部分偏移）‖ v = 0x00 ‖ uint256(n) ‖ signature`，
    /// 即 core 的 `SafeSignatures.encode([.contract(...)])`，也就是 protocol-kit
    /// `buildContractSignature` + `buildSignatureBytes` 对单个签名的结果。
    public static func contract(owner: Address, signature: Data) -> Data {
        // 单个签名不会触发重复 owner / EOA 长度错误。
        try! SafeSignatures.encode([.contract(owner: owner, signature: signature)])
    }
}
