import Foundation

/// 每条链自己填的 RPC 节点。没填的用 `EthRPC.defaultURL`（PublicNode 的公共节点：会限流，也能看到查了哪些地址、来自哪个 IP）。
/// 节点 URL 里常带 API key，所以存钥匙串（`KeychainNamespace`），不存 UserDefaults；界面上只显示打码后的样子。
public struct RPCEndpoints: Hashable, Sendable {
    /// chainID → 自己填的节点。
    public private(set) var custom: [UInt64: URL]

    public init(custom: [UInt64: URL] = [:]) {
        self.custom = custom
    }

    /// 默认节点是谁的（界面上注明）。
    public static let defaultProvider = "PublicNode (publicnode.com)"

    /// 这条链用的节点：自己填的优先，否则默认的公共节点。
    public func url(chainID: UInt64) -> URL? {
        custom[chainID] ?? EthRPC.defaultURL(chainID: chainID)
    }

    public mutating func set(_ url: URL?, chainID: UInt64) {
        custom[chainID] = url
    }

    // MARK: 核对

    public enum Problem: Error, Hashable, Sendable {
        case notAURL
        /// 不是 https（这台 Mac 上的节点，localhost，可以用 http）。
        case notHTTPS
        /// 请求失败或者回的不是链 ID。
        case unreachable
        /// 节点是别的链。
        case wrongChain(UInt64)
    }

    /// 只看写法：能解析、是 https（localhost 例外）。
    public static func parse(_ text: String) -> Result<URL, Problem> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false), !host.isEmpty else {
            return .failure(.notAURL)
        }
        switch scheme {
        case "https": return .success(url)
        case "http": return isLocal(host) ? .success(url) : .failure(.notHTTPS)
        default: return .failure(.notAURL)
        }
    }

    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]" || h.hasSuffix(".localhost")
    }

    /// 保存前的完整核对：写法没问题，再调一次 `eth_chainId`，链 ID 要和这条链一致。
    public static func validate(_ text: String, chainID: UInt64,
                                fetchChainID: (URL) async throws -> UInt64 = { try await EthRPC(url: $0).chainID() }) async -> Result<URL, Problem> {
        let url: URL
        switch parse(text) {
        case .failure(let p): return .failure(p)
        case .success(let u): url = u
        }
        guard let actual = try? await fetchChainID(url) else { return .failure(.unreachable) }
        return actual == chainID ? .success(url) : .failure(.wrongChain(actual))
    }

    // MARK: 显示

    /// 打码显示：保留协议和主机名，路径和查询里只露头尾各 4 个字符（API key 一般在这里）。
    public static func masked(_ url: URL) -> String {
        let scheme = url.scheme ?? "https"
        let host = url.host(percentEncoded: false) ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        var rest = url.path(percentEncoded: true)
        if let q = url.query(percentEncoded: true) { rest += "?" + q }
        if rest == "/" { rest = "" }
        if rest.count > 12 {
            rest = String(rest.prefix(4)) + "••••" + String(rest.suffix(4))
        } else if !rest.isEmpty, rest != "/" {
            rest = String(rest.prefix(1)) + "••••"
        }
        return "\(scheme)://\(host)\(port)\(rest)"
    }

    // MARK: 存储（钥匙串）

    static var item: KeychainItem { KeychainItem(service: KeychainNamespace.service("rpc-endpoints")) }

    /// JSON：{"1": "https://…", "8453": "…"}。
    public func encoded() throws -> Data {
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: custom.map { (String($0.key), $0.value.absoluteString) }))
    }

    public init(decoding data: Data) throws {
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var custom: [UInt64: URL] = [:]
        for (k, v) in raw {
            if let id = UInt64(k), case .success(let url) = Self.parse(v) { custom[id] = url }
        }
        self.init(custom: custom)
    }

    public static func load() -> RPCEndpoints {
        item.read().flatMap { try? RPCEndpoints(decoding: $0) } ?? RPCEndpoints()
    }

    public func save() throws {
        if custom.isEmpty { try Self.item.delete() } else { try Self.item.write(try encoded()) }
    }
}
