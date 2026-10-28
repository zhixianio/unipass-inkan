import CryptoKit
import Foundation
import LocalAuthentication
import Testing
import UniPassCore
@testable import SignerKit

struct SignerProxyTests {
    /// iPhone 15 Pro 的 SE 公钥（xyz.unipass.signer），contracts/ 在 Sepolia 上用 factory.getSigner 核对过的 proxy。
    @Test func deviceKeyProxyAddress() {
        let x = Data(hex: "0x9412d01c528c544a603df018722a38f1a982388e3c688fcc37bfafae34a272dd")!
        let y = Data(hex: "0x19dc995467d9a5cf62f18a144cd44d52bf17553155065e2ca73977d0ce24469d")!
        #expect(SignerProxy.address(x: x, y: y) == Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!)
    }

    @Test func pairingURRoundTrip() throws {
        let key = SoftwareDebugSigningKey()
        let p = SignerProxy.pairing(key: key, name: "iPhone", policy: .currentSet)
        let back = try SignerPairing(ur: UR(parsing: p.ur.qrString))
        #expect(back == p && back.biometryPolicy == .currentSet)
        #expect(back.signerProxy == SignerProxy.address(x: key.publicKeyXY.x, y: key.publicKeyXY.y))
        #expect(SignerProxy.pairing(key: key, name: "x", policy: nil).biometryPolicy == nil)
    }
}

struct TransactionSignerTests {
    static let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
    static let alice = Address(hex: "0x1111111111111111111111111111111111111111")!

    static func signable(key: some P256SigningKey) throws -> SignableTransaction {
        let req = SafeTxRequest(chainID: 11_155_111, safe: safe, tx: SafeTx(to: alice, value: UInt256(1), nonce: UInt256(4)))
        let sign = EthSignRequest(requestID: Data(repeating: 9, count: 16), signData: Data(req.canonicalJSON.utf8), dataType: .typedData,
                                  chainID: 11_155_111, derivationPath: CryptoKeypath(components: [], sourceFingerprint: SignerProxy.identity(key: key).keyFingerprint))
        let ctx = RiskContext(mySafes: [MySafe(chainID: 11_155_111, address: safe)],
                              addressBook: [AddressBookEntry(address: alice, label: "Alice")], signer: SignerProxy.identity(key: key))
        return try SignableTransaction(RiskEngine(context: ctx).assess(signRequest: sign))
    }

    @Test func signsTheAssessedHash() async throws {
        let key = SoftwareDebugSigningKey()
        let tx = try Self.signable(key: key)
        let sig = try await TransactionSigner.sign(tx, with: key, policy: nil, isOffline: { true }, authenticate: { _, _ in })
        #expect(sig.requestID == Data(repeating: 9, count: 16))
        let raw = sig.signature.r.bigEndianBytes + sig.signature.s.bigEndianBytes
        #expect(key.publicKey.isValidSignature(try .init(rawRepresentation: raw), for: sig.assertion.signingMessage(challenge: tx.challenge)))
        #expect(tx.challenge == tx.request.safeTxHash)
        #expect(sig.signature.isLowS)
    }

    @Test func networkCheckedAtSigningTime() async throws {
        let key = SoftwareDebugSigningKey()
        let tx = try Self.signable(key: key)
        await #expect(throws: TransactionSigner.Failure.networkOnline) {
            try await TransactionSigner.sign(tx, with: key, policy: nil, isOffline: { false }, authenticate: { _, _ in })
        }
    }

    /// SE 密钥：先 Face ID，后查联网（模拟器上用假认证验证顺序）。
    @Test func authenticateBeforeNetworkCheck() async throws {
        struct FakeSE: P256SigningKey {
            let inner = SoftwareDebugSigningKey()
            var kind: SigningKeyKind { .secureEnclave }
            var publicKey: P256.Signing.PublicKey { inner.publicKey }
            func rawSignature(for message: Data, context: LAContext?) throws -> Data { try inner.rawSignature(for: message, context: context) }
        }
        let key = FakeSE()
        let tx = try Self.signable(key: key)
        let log = Log()
        _ = try await TransactionSigner.sign(tx, with: key, policy: .anyEnrolled,
                                             isOffline: { log.add("network"); return true },
                                             authenticate: { _, _ in log.add("faceID") })
        #expect(log.entries == ["faceID", "network"])
        await #expect(throws: TransactionSigner.Failure.self) {
            try await TransactionSigner.sign(tx, with: key, policy: .anyEnrolled, isOffline: { true },
                                             authenticate: { _, _ in throw CancellationError() })
        }
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var entries: [String] { lock.withLock { items } }
    }
}

struct SignerStoreTests {
    @Test func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = SafeRegistration(
            chainID: 11_155_111, safe: Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!,
            proxyFactory: Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!,
            singleton: Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!, saltNonce: .zero,
            owners: [Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!, Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!],
            threshold: 2, fallbackHandler: Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!)
        // 只能存 VerifiedSafe：CREATE2 一致，且这台 Signer（这里取 owner[0]）在 owner 里。
        let v = try SafeAddress.verify(r, signer: r.owners[0])
        let a = SignerStore(url: url)
        try a.register(v, name: "测试金库")
        #expect(throws: SignerStore.Failure.duplicateSafe) { try a.register(v, name: nil) }
        try a.addToAddressBook(Address(hex: "0x1111111111111111111111111111111111111111")!, label: " Alice ")
        #expect(throws: SignerStore.Failure.emptyLabel) { try a.addToAddressBook(r.safe, label: "  ") }
        let b = SignerStore(url: url)
        #expect(b.mySafes == [MySafe(chainID: r.chainID, address: r.safe, name: "测试金库", owners: r.owners, threshold: 2)])
        #expect(b.bookEntries.map(\.label) == ["Alice"])
        #expect(b.safes.first?.version == "1.4.1")
        try b.removeFromAddressBook(Address(hex: "0x1111111111111111111111111111111111111111")!)
        #expect(SignerStore(url: url).bookEntries.isEmpty)
    }
}
