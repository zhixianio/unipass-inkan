import CryptoKit
import Foundation
import UniPassCore

/// Signer 的本地数据："我的 Safe"和地址簿。
///
/// 存储选型：Application Support 里的一个 JSON 文件，原子写入，`NSFileProtectionComplete`（锁屏时不可读），
/// 排除出备份。理由：数据量很小、不需要查询；一个 JSON 文件最容易审计；不用 SwiftData / Core Data，
/// 因为它们带着同步机制（CloudKit），离线设备连配置的可能都不该有；Keychain 用来放密钥，不放列表。
///
/// 完整性：拿到解锁手机的人不能悄悄改这些数据（例如把攻击者地址以"冷钱包"的名字加进地址簿，之后转给它就判绿）。
/// - 每次改动都用签名密钥给整份数据签名（SE 密钥会弹 Face ID），签名和数据存在一起，见 `LocalDataSignature`。
///   签整份而不是逐条签：逐条签挡不住"删掉一条"，也挡不住把别处签过的条目拼进来。
/// - 加载时验签。只有验签通过（或者还没有文件）时数据才可用、可改；其余情况（旧版本存的未签名数据、
///   别的密钥签的、签名后被改过、没有可用的密钥、读不出来）都是只读：不参与核对交易，也绝不覆盖原文件。
///   用户看过内容后可以用当前密钥重新签名（`adopt`），或者把文件移到一边、从空数据开始（`setAside`）。
public final class SignerStore: @unchecked Sendable {
    public struct SafeRecord: Codable, Hashable, Sendable {
        public var chainID: UInt64
        public var address: String
        public var name: String?
        public var owners: [String]
        public var threshold: UInt64
        /// 登记时核对过的版本（`SafeAddress.InitCode.version`）。
        public var version: String
        public var registeredAt: Date

        public var mySafe: MySafe {
            MySafe(chainID: chainID, address: Address(hex: address)!, name: name,
                   owners: owners.compactMap(Address.init(hex:)), threshold: threshold)
        }

        var isWellFormed: Bool { Address(hex: address) != nil && owners.allSatisfy { Address(hex: $0) != nil } }
    }

    public struct BookRecord: Codable, Hashable, Sendable {
        public var address: String
        public var label: String
        public var chainID: UInt64?
        public var addedAt: Date

        public var entry: AddressBookEntry { AddressBookEntry(address: Address(hex: address)!, label: label, chainID: chainID) }
    }

    /// 签名覆盖的内容。旧版本的数据文件就是这个结构本身（没有签名）。
    public struct Contents: Codable, Equatable, Sendable {
        var version = 1
        public internal(set) var safes: [SafeRecord] = []
        public internal(set) var addressBook: [BookRecord] = []

        var isWellFormed: Bool { safes.allSatisfy(\.isWellFormed) && addressBook.allSatisfy { Address(hex: $0.address) != nil } }

        /// Safe 名和地址簿名去掉首尾空白、不分大小写后不能重复：重名就能冒充（例如把攻击者的 Safe 也叫"Main vault"）。
        func isNameTaken(_ name: String) -> Bool {
            let n = Self.normalized(name)
            return safes.contains { $0.name.map(Self.normalized) == n } || addressBook.contains { Self.normalized($0.label) == n }
        }

        static func normalized(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: .caseInsensitive, locale: nil)
        }
    }

    /// 文件里存的东西：`payload` 是 `Contents` 的 JSON 原样的字节，签名对它签。
    struct Envelope: Codable {
        var format: Int
        var payload: Data
        /// 签名用的公钥（X9.63）。只用来区分"别的密钥签的"和"签名后被改过"；能不能用只看当前密钥。
        var publicKey: Data
        var signature: Data
    }

    public enum Status: Equatable, Sendable {
        /// 验签通过，或者还没有数据文件：可用、可改。
        case ready
        /// 旧版本存的数据，没有签名。
        case unsigned
        /// 签名有效，但不是这台 iPhone 当前的签名密钥签的（例如原来的密钥删掉后又生成了新的）。
        case signedByAnotherKey
        /// 签名对不上：数据在签名之后被改过。
        case changedAfterSigning
        /// 有签名，但现在没有能读出来的签名密钥，无法验签。
        case cannotVerify
        /// 文件读不出来或解析不了（例如锁屏时读）。
        case unreadable(String)
    }

    public enum Failure: Error, Equatable {
        case duplicateSafe
        case duplicateAddress
        case emptyLabel
        case emptyName
        /// 和已有的 Safe 名或地址簿名重复（不分大小写、去掉首尾空白）。
        case duplicateName
        /// 数据没有通过验签或读不出来，不能改。
        case readOnly
        /// 签名密钥和加载数据时用的不是同一把。
        case wrongKey
        /// 签名期间数据被别的操作改了，这次改动没有保存。
        case changedMeanwhile
        case nothingToAdopt
        case invalidSignature
    }

    /// 一次改动：在内存里的副本上做，校验规则都在这里；签名、写入由 `change` 负责。
    public struct Changes {
        public internal(set) var contents: Contents

        /// 登记一个核对过的 Safe：CREATE2 地址一致，且这台 Signer 在 owner 里（`SafeAddress.verify(_:signer:)`）。
        /// 只收 `VerifiedSafe`，没有别的入口。名字必须是用户在签名器上自己起的，不用桌面端给的名字。
        public mutating func register(_ v: SafeAddress.VerifiedSafe, name: String) throws {
            let r = v.registration
            guard !contents.safes.contains(where: { $0.chainID == r.chainID && Address(hex: $0.address) == r.safe }) else {
                throw Failure.duplicateSafe
            }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Failure.emptyName }
            guard !contents.isNameTaken(name) else { throw Failure.duplicateName }
            contents.safes.append(SafeRecord(chainID: r.chainID, address: r.safe.checksummed, name: name,
                                             owners: r.owners.map(\.checksummed), threshold: r.threshold,
                                             version: v.initCode.version, registeredAt: Date()))
        }

        public mutating func removeSafe(chainID: UInt64, address: Address) {
            contents.safes.removeAll { $0.chainID == chainID && Address(hex: $0.address) == address }
        }

        /// 新地址首次出现时，用户在 Signer 上确认后才入库。
        public mutating func addToAddressBook(_ address: Address, label: String, chainID: UInt64? = nil) throws {
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { throw Failure.emptyLabel }
            guard !contents.addressBook.contains(where: { Address(hex: $0.address) == address }) else { throw Failure.duplicateAddress }
            guard !contents.isNameTaken(label) else { throw Failure.duplicateName }
            contents.addressBook.append(BookRecord(address: address.checksummed, label: label, chainID: chainID, addedAt: Date()))
        }

        public mutating func removeFromAddressBook(_ address: Address) {
            contents.addressBook.removeAll { Address(hex: $0.address) == address }
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var status_: Status = .ready
    /// 验签通过的数据；其余状态下为空。
    private var trusted = Contents()
    /// 没通过验签的数据，只给用户看。
    private var unverified: Contents?
    private var verifyingKey: P256.Signing.PublicKey?
    private var generation = 0

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appending(path: "signer-store.json")
    }

    /// `publicKey` 是这台 iPhone 当前签名密钥的公钥；没有能读出来的密钥时传 nil（有签名的数据就无法验签）。
    public init(url: URL = SignerStore.defaultURL, publicKey: P256.Signing.PublicKey? = nil) {
        self.url = url
        reload(publicKey: publicKey)
    }

    public var status: Status { lock.withLock { status_ } }
    public var safes: [SafeRecord] { lock.withLock { trusted.safes } }
    public var addressBook: [BookRecord] { lock.withLock { trusted.addressBook } }
    public var mySafes: [MySafe] { safes.map(\.mySafe) }
    public var bookEntries: [AddressBookEntry] { addressBook.map(\.entry) }
    /// 只读状态下文件里的内容（读不出来时为 nil）。不参与核对交易。
    public var unverifiedContents: Contents? { lock.withLock { unverified } }

    public func isNameTaken(_ name: String) -> Bool { lock.withLock { trusted.isNameTaken(name) } }

    /// 重新读文件并验签。签名密钥变了（生成、删除、重新读出）之后要调用。
    public func reload(publicKey: P256.Signing.PublicKey?) {
        let (status, trusted, unverified) = Self.load(url: url, publicKey: publicKey)
        lock.withLock {
            verifyingKey = publicKey
            status_ = status
            self.trusted = trusted
            self.unverified = unverified
            generation += 1
        }
    }

    static func load(url: URL, publicKey: P256.Signing.PublicKey?) -> (Status, Contents, Contents?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.ready, Contents(), nil) }
        // 用 path 版本读：`Data(contentsOf: URL)` 遇到 http URL 会联网，无网络检查不允许它。
        guard let data = FileManager.default.contents(atPath: url.path) else { return (.unreadable("read"), Contents(), nil) }
        let decoder = Self.decoder
        if let env = try? decoder.decode(Envelope.self, from: data), env.format == 2 {
            guard let contents = try? decoder.decode(Contents.self, from: env.payload), contents.isWellFormed,
                  let signedBy = try? P256.Signing.PublicKey(x963Representation: env.publicKey)
            else { return (.unreadable("payload"), Contents(), nil) }
            guard let publicKey else { return (.cannotVerify, Contents(), contents) }
            if publicKey.x963Representation == env.publicKey {
                return LocalDataSignature.isValid(env.signature, payload: env.payload, publicKey: publicKey)
                    ? (.ready, contents, nil) : (.changedAfterSigning, Contents(), contents)
            }
            return LocalDataSignature.isValid(env.signature, payload: env.payload, publicKey: signedBy)
                ? (.signedByAnotherKey, Contents(), contents) : (.changedAfterSigning, Contents(), contents)
        }
        if let contents = try? decoder.decode(Contents.self, from: data), contents.isWellFormed {
            return (.unsigned, Contents(), contents)
        }
        return (.unreadable("format"), Contents(), nil)
    }

    /// 改动数据：在副本上做 `body`，用 `signer` 签名（SE 密钥会弹 Face ID），签好才写文件、才生效。
    /// 签名失败或取消时什么都不变。只读状态下抛 `readOnly`。
    public func change(signer: LocalDataSigner, _ body: @Sendable (inout Changes) throws -> Void) async throws {
        let (base, gen) = try lock.withLock {
            guard status_ == .ready else { throw Failure.readOnly }
            guard verifyingKey?.x963Representation == signer.publicKey.x963Representation else { throw Failure.wrongKey }
            return (trusted, generation)
        }
        var changes = Changes(contents: base)
        try body(&changes)
        try await commit(changes.contents, signer: signer) { $0.generation == gen && $0.status_ == .ready }
    }

    public func register(_ v: SafeAddress.VerifiedSafe, name: String, signer: LocalDataSigner) async throws {
        try await change(signer: signer) { try $0.register(v, name: name) }
    }

    public func removeSafe(chainID: UInt64, address: Address, signer: LocalDataSigner) async throws {
        try await change(signer: signer) { $0.removeSafe(chainID: chainID, address: address) }
    }

    public func addToAddressBook(_ address: Address, label: String, chainID: UInt64? = nil, signer: LocalDataSigner) async throws {
        try await change(signer: signer) { try $0.addToAddressBook(address, label: label, chainID: chainID) }
    }

    public func removeFromAddressBook(_ address: Address, signer: LocalDataSigner) async throws {
        try await change(signer: signer) { $0.removeFromAddressBook(address) }
    }

    /// 用当前密钥重新签名只读的数据时会留下什么：签名人里没有 `signerAddress`（这台 iPhone 当前的签名人地址）的 Safe 不留，
    /// "我的 Safe"只收这台 iPhone 是签名人的 Safe；地址簿全部保留。
    public func adoption(signerAddress: Address) -> (kept: Contents, droppedSafes: [SafeRecord])? {
        guard var c = unverifiedContents else { return nil }
        let dropped = c.safes.filter { !$0.owners.contains { Address(hex: $0) == signerAddress } }
        c.safes.removeAll { dropped.contains($0) }
        return (c, dropped)
    }

    /// 用户看过只读的数据后，用当前密钥重新签名并开始使用（见 `adoption`）。
    public func adopt(signer: LocalDataSigner, signerAddress: Address) async throws {
        let gen = try lock.withLock {
            guard status_ != .ready, unverified != nil else { throw Failure.nothingToAdopt }
            guard verifyingKey?.x963Representation == signer.publicKey.x963Representation else { throw Failure.wrongKey }
            return generation
        }
        guard let (kept, _) = adoption(signerAddress: signerAddress) else { throw Failure.nothingToAdopt }
        try await commit(kept, signer: signer) { $0.generation == gen }
    }

    /// 把只读的数据文件改名放到一边（同一目录，`signer-store.set-aside-<时间>.json`，不删除），然后从空数据开始。
    /// 返回放到哪里了。
    @discardableResult
    public func setAside() throws -> URL {
        try lock.withLock {
            guard status_ != .ready else { throw Failure.readOnly }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let dest = url.deletingLastPathComponent().appending(path: "signer-store.set-aside-\(stamp).json")
            try FileManager.default.moveItem(at: url, to: dest)
            status_ = .ready
            trusted = Contents()
            unverified = nil
            generation += 1
            return dest
        }
    }

    private func commit(_ contents: Contents, signer: LocalDataSigner, unchanged: (SignerStore) -> Bool) async throws {
        let encoder = Self.encoder
        let payload = try encoder.encode(contents)
        let signature = try await signer.sign(payload: payload)
        guard LocalDataSignature.isValid(signature, payload: payload, publicKey: signer.publicKey) else { throw Failure.invalidSignature }
        let file = try encoder.encode(Envelope(format: 2, payload: payload, publicKey: signer.publicKey.x963Representation, signature: signature))
        try lock.withLock {
            guard unchanged(self) else { throw Failure.changedMeanwhile }
            try write(file)
            status_ = .ready
            trusted = contents
            unverified = nil
            generation += 1
        }
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
