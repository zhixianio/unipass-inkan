import CryptoKit
import Foundation
import Testing
import UniPassCore
@testable import SignerKit

/// 本地数据（"我的 Safe"、地址簿）的完整性：每次改动都签名，加载时验签，读不出或验不过就只读、绝不覆盖原文件。
@Suite struct SignerStoreTests {
    static let alice = Address(hex: "0x1111111111111111111111111111111111111111")!
    static let mallory = Address(hex: "0x2222222222222222222222222222222222222222")!

    static func tempURL() -> URL { FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)/signer-store.json") }

    static func registration(signer: Address = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!) -> SafeAddress.VerifiedSafe {
        var r = SafeRegistration(
            chainID: 11_155_111, safe: .zero,
            proxyFactory: Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!,
            singleton: Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!, saltNonce: .zero,
            owners: [signer, Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!],
            threshold: 2, fallbackHandler: Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!, name: "Main vault")
        r.safe = SafeAddress.compute(r)!
        return try! SafeAddress.verify(r, signer: signer)
    }

    /// 软件密钥签名，并记下签了几次。
    final class CountingSigner: @unchecked Sendable {
        let key = SoftwareDebugSigningKey()
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        var signer: LocalDataSigner {
            LocalDataSigner(publicKey: key.publicKey) { [self] m in
                lock.withLock { n += 1 }
                return try key.rawSignature(for: m)
            }
        }
    }

    static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    @Test func roundTrip() async throws {
        let url = Self.tempURL()
        let k = CountingSigner()
        let v = Self.registration()
        let a = SignerStore(url: url, publicKey: k.key.publicKey)
        try await a.register(v, name: " 测试金库 ", signer: k.signer)
        await #expect(throws: SignerStore.Failure.duplicateSafe) { try await a.register(v, name: "另一个", signer: k.signer) }
        try await a.addToAddressBook(Self.alice, label: " Alice ", signer: k.signer)
        await #expect(throws: SignerStore.Failure.emptyLabel) { try await a.addToAddressBook(Self.mallory, label: "  ", signer: k.signer) }
        let b = SignerStore(url: url, publicKey: k.key.publicKey)
        #expect(b.status == .ready)
        #expect(b.mySafes == [MySafe(chainID: v.registration.chainID, address: v.registration.safe, name: "测试金库",
                                     owners: v.registration.owners, threshold: 2)])
        #expect(b.bookEntries.map(\.label) == ["Alice"])
        #expect(b.safes.first?.version == "1.4.1")
        try await b.removeFromAddressBook(Self.alice, signer: k.signer)
        #expect(SignerStore(url: url, publicKey: k.key.publicKey).bookEntries.isEmpty)
        // 每次改动签一次；被拒绝的改动不签。
        #expect(k.count == 3)
    }

    /// 签名被取消（例如 Face ID 取消）时什么都不变。
    @Test func cancelledSignatureChangesNothing() async throws {
        let url = Self.tempURL()
        let k = CountingSigner()
        let s = SignerStore(url: url, publicKey: k.key.publicKey)
        try await s.addToAddressBook(Self.alice, label: "Alice", signer: k.signer)
        let before = Self.bytes(url)
        struct Cancelled: Error {}
        let cancelling = LocalDataSigner(publicKey: k.key.publicKey) { _ in throw Cancelled() }
        await #expect(throws: Cancelled.self) { try await s.addToAddressBook(Self.mallory, label: "Cold wallet", signer: cancelling) }
        #expect(s.bookEntries.map(\.label) == ["Alice"])
        #expect(Self.bytes(url) == before)
    }

    /// 文件读不出来时只读，改动被拒绝，原文件一个字节都不变（以前会当成空库，下次保存就把它覆盖掉）。
    @Test func unreadableFileIsReadOnlyAndNeverOverwritten() async throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ not json".utf8)
        try original.write(to: url)
        let k = CountingSigner()
        let s = SignerStore(url: url, publicKey: k.key.publicKey)
        guard case .unreadable = s.status else { Issue.record("\(s.status)"); return }
        await #expect(throws: SignerStore.Failure.readOnly) { try await s.addToAddressBook(Self.alice, label: "Cold wallet", signer: k.signer) }
        await #expect(throws: SignerStore.Failure.nothingToAdopt) { try await s.adopt(signer: k.signer, signerAddress: Self.alice) }
        #expect(Self.bytes(url) == original)
        #expect(k.count == 0)
    }

    /// 有人改了文件（不管是改签过的数据，还是换成没签名的旧格式）：不信任，只读，不参与核对。
    @Test func editedFileIsNotTrusted() async throws {
        let url = Self.tempURL()
        let k = CountingSigner()
        let s = SignerStore(url: url, publicKey: k.key.publicKey)
        try await s.addToAddressBook(Self.alice, label: "Alice", signer: k.signer)

        // 在签过的数据里塞一条攻击者地址，签名不动。
        var env = try JSONDecoder().decode(SignerStore.Envelope.self, from: Self.bytes(url)!)
        let payload = String(decoding: env.payload, as: UTF8.self)
            .replacingOccurrences(of: Self.alice.checksummed, with: Self.mallory.checksummed)
            .replacingOccurrences(of: "Alice", with: "Cold wallet")
        env.payload = Data(payload.utf8)
        let tampered = try JSONEncoder().encode(env)
        try tampered.write(to: url)
        let t = SignerStore(url: url, publicKey: k.key.publicKey)
        #expect(t.status == .changedAfterSigning)
        #expect(t.bookEntries.isEmpty)
        #expect(t.unverifiedContents?.addressBook.map(\.label) == ["Cold wallet"])
        await #expect(throws: SignerStore.Failure.readOnly) { try await t.addToAddressBook(Self.alice, label: "Alice 2", signer: k.signer) }
        #expect(Self.bytes(url) == tampered)

        // 换成旧版本那种没有签名的格式。
        try Data(#"{"version":1,"safes":[],"addressBook":[{"address":"0x2222222222222222222222222222222222222222","label":"Cold wallet","addedAt":"2026-10-28T00:00:00Z"}]}"#.utf8).write(to: url)
        let u = SignerStore(url: url, publicKey: k.key.publicKey)
        #expect(u.status == .unsigned)
        #expect(u.bookEntries.isEmpty)
    }

    /// 别的密钥签的（例如攻击者用自己的密钥签，或者原来的密钥删掉后又生成了新的）：不信任。没有可用的密钥时无法验签。
    @Test func otherKeyOrNoKey() async throws {
        let url = Self.tempURL()
        let old = CountingSigner(), new = CountingSigner()
        try await SignerStore(url: url, publicKey: old.key.publicKey).addToAddressBook(Self.alice, label: "Alice", signer: old.signer)
        let s = SignerStore(url: url, publicKey: new.key.publicKey)
        #expect(s.status == .signedByAnotherKey)
        #expect(s.bookEntries.isEmpty)
        #expect(SignerStore(url: url, publicKey: nil).status == .cannotVerify)
        // 用别的密钥签名改动也不行。
        let fresh = SignerStore(url: Self.tempURL(), publicKey: new.key.publicKey)
        await #expect(throws: SignerStore.Failure.wrongKey) { try await fresh.addToAddressBook(Self.alice, label: "Alice", signer: old.signer) }
    }

    /// 旧版本的未签名数据：用户看过后用当前密钥签名，开始使用；签名人里没有本机的 Safe 不留。
    @Test func adoptUnsignedData() async throws {
        let url = Self.tempURL()
        let me = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!
        let mine = Self.registration(signer: me), other = Self.registration(signer: Self.mallory)
        var legacy = SignerStore.Contents()
        for v in [mine, other] {
            legacy.safes.append(.init(chainID: v.registration.chainID, address: v.registration.safe.checksummed, name: "Safe \(legacy.safes.count)",
                                      owners: v.registration.owners.map(\.checksummed), threshold: 2, version: "1.4.1", registeredAt: Date()))
        }
        legacy.addressBook.append(.init(address: Self.alice.checksummed, label: "Alice", chainID: nil, addedAt: Date()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(legacy).write(to: url)

        let k = CountingSigner()
        let s = SignerStore(url: url, publicKey: k.key.publicKey)
        #expect(s.status == .unsigned)
        #expect(s.adoption(signerAddress: me)?.droppedSafes.map(\.name) == ["Safe 1"])
        try await s.adopt(signer: k.signer, signerAddress: me)
        #expect(s.status == .ready)
        #expect(s.safes.map(\.name) == ["Safe 0"])
        #expect(s.bookEntries.map(\.label) == ["Alice"])
        #expect(SignerStore(url: url, publicKey: k.key.publicKey).status == .ready)
        #expect(k.count == 1)
    }

    /// 放到一边：原文件改名保留，字节不变；之后从空数据开始。
    @Test func setAsideKeepsTheFile() async throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ not json".utf8)
        try original.write(to: url)
        let k = CountingSigner()
        let s = SignerStore(url: url, publicKey: k.key.publicKey)
        let moved = try s.setAside()
        #expect(Self.bytes(moved) == original)
        #expect(s.status == .ready)
        try await s.addToAddressBook(Self.alice, label: "Alice", signer: k.signer)
        #expect(SignerStore(url: url, publicKey: k.key.publicKey).bookEntries.map(\.label) == ["Alice"])
        #expect(Self.bytes(moved) == original)
        // 可用的数据不能放到一边。
        #expect(throws: SignerStore.Failure.readOnly) { try s.setAside() }
    }

    // MARK: 名字

    /// 登记 Safe 必须由用户起名；名字（去掉首尾空白、不分大小写）不能和已有的 Safe 名、地址簿名重复。
    @Test func safeNamesAreRequiredAndUnique() async throws {
        let k = CountingSigner()
        let s = SignerStore(url: Self.tempURL(), publicKey: k.key.publicKey)
        let a = Self.registration(), b = Self.registration(signer: Address(hex: "0x3333333333333333333333333333333333333333")!)
        await #expect(throws: SignerStore.Failure.emptyName) { try await s.register(a, name: "   ", signer: k.signer) }
        try await s.register(a, name: "Main vault", signer: k.signer)
        await #expect(throws: SignerStore.Failure.duplicateName) { try await s.register(b, name: "  main VAULT ", signer: k.signer) }
        try await s.addToAddressBook(Self.alice, label: "Cold wallet", signer: k.signer)
        await #expect(throws: SignerStore.Failure.duplicateName) { try await s.register(b, name: "COLD WALLET", signer: k.signer) }
        await #expect(throws: SignerStore.Failure.duplicateName) { try await s.addToAddressBook(Self.mallory, label: "main vault", signer: k.signer) }
        #expect(s.isNameTaken(" Main Vault"))
        #expect(!s.isNameTaken("Savings"))
        try await s.register(b, name: "Savings", signer: k.signer)
        #expect(s.safes.map(\.name) == ["Main vault", "Savings"])
    }

    /// 桌面端给的名字不用：存下来的是用户输入的名字。
    @Test func registrationNameFromDesktopIsIgnored() async throws {
        let k = CountingSigner()
        let s = SignerStore(url: Self.tempURL(), publicKey: k.key.publicKey)
        let v = Self.registration()
        #expect(v.registration.name == "Main vault")
        try await s.register(v, name: "Family", signer: k.signer)
        #expect(s.safes.map(\.name) == ["Family"])
    }
}

/// 本地数据的签名绝不能被当成有效的 Safe 签名（同一把密钥也是 Safe 的签名人）。
@Suite struct LocalDataSignatureTests {
    /// 合约（safe-modules 的 WebAuthn 库）接受签名的条件，见 docs/webauthn-signature.md：
    /// 签名消息 = authenticatorData ‖ sha256(clientDataJSON)，且 authenticatorData[32] 的 UV 位（0x04）置位。
    static func contractAccepts(authenticatorData: Data, clientDataFields: String, challenge: Data,
                                signature: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard authenticatorData.count > 32, authenticatorData[authenticatorData.startIndex + 32] & 0x04 != 0,
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        let a = WebAuthnAssertion(authenticatorData: authenticatorData, clientDataFields: clientDataFields)
        return publicKey.isValidSignature(sig, for: a.signingMessage(challenge: challenge))
    }

    @Test func layout() {
        let m = LocalDataSignature.message(for: Data("{}".utf8))
        #expect(m.count == 65)
        #expect(m.prefix(32) == LocalDataSignature.tag)
        #expect(LocalDataSignature.tag.count == 32)
        // 和 Safe 签名的 authenticatorData 开头（rpIdHash = sha256("unipass.xyz")）不同。
        #expect(m.prefix(32) != WebAuthnAssertion.signerDefault.authenticatorData.prefix(32))
        #expect(m[32] == 0)
    }

    /// 不管存的是什么，签名消息第 33 个字节的 UV 位都没有置位；合约那边能对上这条消息的拆分只有一种，它必然失败。
    @Test func neverAcceptedAsSafeSignature() throws {
        let key = SoftwareDebugSigningKey()
        for _ in 0..<200 {
            let payload = Data((0..<Int.random(in: 0...300)).map { _ in UInt8.random(in: 0...255) })
            let m = LocalDataSignature.message(for: payload)
            #expect(m[32] & 0x04 == 0)
            let sig = try key.rawSignature(for: m)
            #expect(LocalDataSignature.isValid(sig, payload: payload, publicKey: key.publicKey))
            // 合约的消息是 authenticatorData ‖ 32 字节哈希，所以 authenticatorData 只能是前 33 字节。
            let authData = m.prefix(m.count - 32)
            #expect(authData.count == 33)
            for fields in [WebAuthnAssertion.signerDefault.clientDataFields, ""] {
                for challenge in [Data(m.suffix(32)), Data(SHA256.hash(data: payload)), Data(count: 32)] {
                    #expect(!Self.contractAccepts(authenticatorData: authData, clientDataFields: fields, challenge: challenge,
                                                  signature: sig, publicKey: key.publicKey))
                }
            }
        }
    }

    /// 反过来：Safe 交易的签名（同一把密钥）也不能被当成本地数据的签名。
    @Test func safeSignatureIsNotALocalDataSignature() throws {
        let key = SoftwareDebugSigningKey()
        let challenge = Data(repeating: 0xAB, count: 32)
        let signed = try WebAuthnSigner.sign(challenge: challenge, with: key)
        let raw = signed.signature.r.bigEndianBytes + signed.signature.s.bigEndianBytes
        let message = WebAuthnAssertion.signerDefault.signingMessage(challenge: challenge)
        #expect(message[32] & 0x04 != 0)
        // 对照：上面的合约模型确实接受真正的 Safe 签名，所以前一个测试里的"不接受"不是模型本身的问题。
        #expect(Self.contractAccepts(authenticatorData: WebAuthnAssertion.signerDefault.authenticatorData,
                                     clientDataFields: WebAuthnAssertion.signerDefault.clientDataFields, challenge: challenge,
                                     signature: raw, publicKey: key.publicKey))
        for payload in [message, Data(message.suffix(32)), challenge] {
            #expect(!LocalDataSignature.isValid(raw, payload: payload, publicKey: key.publicKey))
        }
    }
}
