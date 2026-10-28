import Foundation

/// 内置标签库（`Resources/labels.json`）：三条链上的 Safe 官方合约、Permit2、主流代币。
/// 每条都注明来源；拿不准的不收。生成方式见 docs/rules.md「标签库」。
public struct LabelLibrary: Sendable {
    public enum Kind: String, Codable, Sendable {
        case safeSingleton
        case safeProxyFactory
        case safeFallbackHandler
        /// MultiSend、CreateCall、SignMessageLib、迁移合约等，通常被 DELEGATECALL 调用。
        case safeLibrary
        case permit2
        case erc20
        case erc721
        case erc1155
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var chainId: UInt64
        public var address: String
        public var kind: Kind
        public var name: String
        public var symbol: String?
        public var decimals: Int?
        public var source: String

        public var parsedAddress: Address? { Address(hex: address) }
        public var isToken: Bool { [.erc20, .erc721, .erc1155].contains(kind) }
    }

    struct File: Codable {
        var version: Int
        var entries: [Entry]
    }

    public let entries: [Entry]
    private let index: [String: Entry]

    private static func key(_ chainID: UInt64, _ address: Address) -> String { "\(chainID):\(address.bytes.hexString)" }

    public init(entries: [Entry]) {
        self.entries = entries
        var index: [String: Entry] = [:]
        for e in entries {
            if let a = e.parsedAddress { index[Self.key(e.chainId, a)] = e }
        }
        self.index = index
    }

    public init(json: Data) throws {
        self.init(entries: try JSONDecoder().decode(File.self, from: json).entries)
    }

    /// App 内置的标签库。
    public static let builtIn: LabelLibrary = {
        // 不用 Data(contentsOf: URL)：它遇到 http URL 会联网，无网络检查会拦。
        guard let path = Bundle.module.path(forResource: "labels", ofType: "json"),
              let data = FileManager.default.contents(atPath: path), let lib = try? LabelLibrary(json: data)
        else { return LabelLibrary(entries: []) }
        return lib
    }()

    public func lookup(chainID: UInt64, address: Address) -> Entry? {
        index[Self.key(chainID, address)]
    }

    /// 同一条链上符号或名称相同（不区分大小写）的代币。用于 R09「同名不同地址」。
    public func tokens(chainID: UInt64, named name: String) -> [Entry] {
        let n = name.lowercased()
        return entries.filter { $0.chainId == chainID && $0.isToken && ($0.symbol?.lowercased() == n || $0.name.lowercased() == n) }
    }
}
