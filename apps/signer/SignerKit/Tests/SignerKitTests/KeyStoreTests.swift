import Foundation
import Security
import Testing
@testable import SignerKit

/// 读取密钥失败（例如锁屏时被预热启动）时，首页不能把用户引到"生成新密钥"，生成也绝不能覆盖已有的条目：
/// 那会把 Safe 签名人的密钥永久删掉（安全核查 P2-6）。
@Suite(.serialized) struct KeyStoreTests {
    static func store() -> KeyStore { KeyStore(service: "test.unipass.keystore.\(UUID().uuidString)", account: "owner-key-v0") }

    static func insertRaw(_ s: KeyStore, _ value: Data) throws {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: s.service, kSecAttrAccount: s.account,
                                     kSecAttrSynchronizable: false, kSecValueData: value]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStore.Failure.keychain(status) }
    }

    @Test func generateNeverReplacesAnExistingEntry() throws {
        let s = Self.store()
        defer { try? s.delete() }
        // 一个读不出来的条目（种类字节不认识）：load 报错，generate 也必须拒绝，条目原样保留。
        try Self.insertRaw(s, Data([0xEE, 1, 2, 3]))
        #expect(throws: KeyStore.Failure.self) { try s.load() }
        #expect(throws: KeyStore.Failure.keyExists) { try s.generate(policy: .currentSet) }
        #expect(s.hasEntry)
        #expect(throws: KeyStore.Failure.self) { try s.load() }
    }

    /// 设置里"删除读不出的签名密钥"：只删读不出来的条目，删完能生成新密钥。
    @Test func unreadableEntryCanBeDeletedThenANewKeyCreated() throws {
        let s = Self.store()
        defer { try? s.delete() }
        try Self.insertRaw(s, Data([0xEE, 1, 2, 3]))
        try s.deleteUnreadable()
        #expect(!s.hasEntry)
        let created = try s.generate(policy: .currentSet)
        #expect(try s.load()?.key.publicKey.rawRepresentation == created.key.publicKey.rawRepresentation)
    }

    /// 旧格式（没有 `kSecAttrGeneric`）的 SE 条目，数据坏了读不出来，也要能删。
    @Test func unreadableLegacyEntryCanBeDeleted() throws {
        let s = Self.store()
        defer { try? s.delete() }
        try Self.insertRaw(s, Data([SigningKeyKind.secureEnclave.rawValue]) + Data(repeating: 7, count: 32))
        #expect(throws: (any Error).self) { try s.load() }
        try s.deleteUnreadable()
        #expect(!s.hasEntry)
    }

    /// 能读出来的密钥不能用这个入口删：报错，条目原样保留。
    @Test func readableKeyIsNotDeletedAsUnreadable() throws {
        let s = Self.store()
        defer { try? s.delete() }
        let created = try s.generate(policy: .currentSet)
        #expect(throws: KeyStore.Failure.keyReadable) { try s.deleteUnreadable() }
        #expect(s.hasEntry)
        #expect(try s.load()?.key.publicKey.rawRepresentation == created.key.publicKey.rawRepresentation)
    }

    @Test func noEntryMeansNothingStored() throws {
        let s = Self.store()
        #expect(try s.load() == nil)
        #expect(!s.hasEntry)
    }
}
