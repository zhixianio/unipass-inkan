import Foundation
import UniPassCore

/// 这台 Mac 配对过的签名器。一个 Safe 里可以有几台 iPhone 当签名人，每台都要能从这里收到签名请求，
/// 所以是一个列表，按配对顺序；第一台是欢迎引导里配的那台。
///
/// 每台有一个这台 Mac 上的名字：默认用签名器自己报的设备名（一般是"iPhone"），重名时加编号（"iPhone 2"），可以改。
/// 名字只用来显示，签名请求只认公钥和 proxy 地址。
public struct PairedSigners: Hashable, Sendable {
    public private(set) var all: [PairedSigner]

    public init(_ all: [PairedSigner] = []) {
        self.all = all
    }

    public var isEmpty: Bool { all.isEmpty }
    public var first: PairedSigner? { all.first }
    public var proxies: Set<Address> { Set(all.map(\.signerProxy)) }

    public func signer(_ proxy: Address) -> PairedSigner? {
        all.first { $0.signerProxy == proxy }
    }

    public func contains(_ proxy: Address) -> Bool {
        signer(proxy) != nil
    }

    /// 这个 Safe 里的已配对签名器，按 owner 的顺序。
    public func inSafe(_ owners: [Address]) -> [PairedSigner] {
        owners.compactMap { signer($0) }
    }

    /// 同一个 proxy 已经配对过，带来的公钥却不一样。
    public struct KeyChanged: Error, Hashable, Sendable {}

    /// 配对一台。同一台（同一个 proxy、同一把公钥）再配对一次时更新它的信息、保留这台 Mac 上的名字和位置；
    /// 同一个 proxy 换了公钥的不收（抛 `KeyChanged`，原来那条不变）。新的一台排在最后，名字不和已有的重复。
    /// 返回存下来的那条。
    @discardableResult
    public mutating func add(_ s: PairedSigner) throws(KeyChanged) -> PairedSigner {
        var s = s
        if let i = all.firstIndex(where: { $0.signerProxy == s.signerProxy }) {
            guard all[i].hasSameKey(as: s.pairing) else { throw KeyChanged() }
            s.name = all[i].name
            all[i] = s
            return s
        }
        s.name = Self.uniqueName(s.name, taken: Set(all.map(\.name)))
        all.append(s)
        return s
    }

    public mutating func remove(_ proxy: Address) {
        all.removeAll { $0.signerProxy == proxy }
    }

    public enum RenameProblem: Error, Hashable, Sendable {
        case empty
        case taken
    }

    /// 改名：去掉首尾空白，不能为空，不能和另一台重名（不分大小写）。
    public mutating func rename(_ proxy: Address, to name: String) -> RenameProblem? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return .empty }
        guard let i = all.firstIndex(where: { $0.signerProxy == proxy }) else { return nil }
        if all.contains(where: { $0.signerProxy != proxy && $0.name.lowercased() == n.lowercased() }) { return .taken }
        all[i].name = n
        return nil
    }

    /// "iPhone" 没人用就用它，否则 "iPhone 2"、"iPhone 3"……空名字当 "iPhone"。
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "iPhone" : trimmed
        let lowered = Set(taken.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        var n = 2
        while lowered.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: 存储

    /// 读本地存的列表；没有或读不出来时是空列表。
    public static func load(_ data: Data?) -> PairedSigners {
        data.flatMap { try? JSONDecoder().decode([PairedSigner].self, from: $0) }.map(PairedSigners.init) ?? PairedSigners()
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(all)
    }
}
