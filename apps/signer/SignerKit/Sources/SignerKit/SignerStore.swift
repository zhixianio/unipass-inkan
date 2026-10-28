import Foundation
import UniPassCore

/// Signer 的本地数据："我的 Safe"和地址簿。
///
/// 存储选型：Application Support 里的一个 JSON 文件，原子写入，`NSFileProtectionComplete`（锁屏时不可读），
/// 排除出备份。理由：数据量很小、不需要查询；一个 JSON 文件最容易审计；不用 SwiftData / Core Data，
/// 因为它们带着同步机制（CloudKit），离线设备连配置的可能都不该有；Keychain 用来放密钥，不放列表。
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
    }

    public struct BookRecord: Codable, Hashable, Sendable {
        public var address: String
        public var label: String
        public var chainID: UInt64?
        public var addedAt: Date

        public var entry: AddressBookEntry { AddressBookEntry(address: Address(hex: address)!, label: label, chainID: chainID) }
    }

    struct File: Codable {
        var version = 1
        var safes: [SafeRecord] = []
        var addressBook: [BookRecord] = []
    }

    public enum Failure: Error, Equatable {
        case duplicateSafe
        case duplicateAddress
        case emptyLabel
    }

    private let url: URL
    private var file: File
    private let lock = NSLock()

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appending(path: "signer-store.json")
    }

    public init(url: URL = SignerStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = FileManager.default.contents(atPath: url.path), let f = try? decoder.decode(File.self, from: data) {
            file = f
        } else {
            file = File()
        }
    }

    public var safes: [SafeRecord] { lock.withLock { file.safes } }
    public var addressBook: [BookRecord] { lock.withLock { file.addressBook } }
    public var mySafes: [MySafe] { safes.map(\.mySafe) }
    public var bookEntries: [AddressBookEntry] { addressBook.map(\.entry) }

    /// 登记一个核对过的 Safe：CREATE2 地址一致，且这台 Signer 在 owner 里（`SafeAddress.verify(_:signer:)`）。
    /// 只收 `VerifiedSafe`，没有别的入口。
    public func register(_ v: SafeAddress.VerifiedSafe, name: String?) throws {
        let r = v.registration, verified = v.initCode
        try lock.withLock {
            guard !file.safes.contains(where: { $0.chainID == r.chainID && Address(hex: $0.address) == r.safe }) else {
                throw Failure.duplicateSafe
            }
            file.safes.append(SafeRecord(chainID: r.chainID, address: r.safe.checksummed, name: name ?? r.name,
                                         owners: r.owners.map(\.checksummed), threshold: r.threshold,
                                         version: verified.version, registeredAt: Date()))
        }
        try save()
    }

    public func removeSafe(chainID: UInt64, address: Address) throws {
        lock.withLock { file.safes.removeAll { $0.chainID == chainID && Address(hex: $0.address) == address } }
        try save()
    }

    /// 新地址首次出现时，用户在 Signer 上确认后才入库。
    public func addToAddressBook(_ address: Address, label: String, chainID: UInt64? = nil) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw Failure.emptyLabel }
        try lock.withLock {
            guard !file.addressBook.contains(where: { Address(hex: $0.address) == address }) else { throw Failure.duplicateAddress }
            file.addressBook.append(BookRecord(address: address.checksummed, label: label, chainID: chainID, addedAt: Date()))
        }
        try save()
    }

    public func removeFromAddressBook(_ address: Address) throws {
        lock.withLock { file.addressBook.removeAll { Address(hex: $0.address) == address } }
        try save()
    }

    private func save() throws {
        let data = try lock.withLock {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            return try e.encode(file)
        }
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
}
