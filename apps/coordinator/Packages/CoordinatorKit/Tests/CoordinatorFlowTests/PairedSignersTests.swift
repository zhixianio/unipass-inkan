import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

@Suite struct PairedSignersTests {
    static let proxyA = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!
    static let proxyB = Address(hex: "0x00000000000000000000000000000000000000B2")!
    static let proxyC = Address(hex: "0x00000000000000000000000000000000000000C3")!

    static func signer(_ proxy: Address, name: String = "iPhone") -> PairedSigner {
        PairedSigner(SoftwareSigner(name: name, proxy: proxy).pairing)
    }

    static func signer(_ s: SoftwareSigner) -> PairedSigner {
        PairedSigner(s.pairing)
    }

    @Test func defaultNamesAreNumbered() {
        #expect(PairedSigners.uniqueName("iPhone", taken: []) == "iPhone")
        #expect(PairedSigners.uniqueName("iPhone", taken: ["iPhone"]) == "iPhone 2")
        #expect(PairedSigners.uniqueName("iphone", taken: ["iPhone", "iPhone 2"]) == "iphone 3")
        #expect(PairedSigners.uniqueName("  ", taken: []) == "iPhone")
        #expect(PairedSigners.uniqueName("Work Phone", taken: ["iPhone"]) == "Work Phone")
    }

    @Test func pairingAddsAndRepairingUpdatesInPlace() throws {
        var list = PairedSigners()
        let phoneA = SoftwareSigner(name: "iPhone", proxy: Self.proxyA)
        #expect(try list.add(Self.signer(phoneA)).name == "iPhone")
        #expect(try list.add(Self.signer(Self.proxyB)).name == "iPhone 2")
        #expect(list.all.map(\.signerProxy) == [Self.proxyA, Self.proxyB])

        // 同一台再配对：位置和这台 Mac 上的名字不变，其他信息换成新的。
        #expect(list.rename(Self.proxyA, to: "Alice's iPhone") == nil)
        var again = Self.signer(phoneA)
        again.verifiedOnChain = true
        let stored = try list.add(again)
        #expect(stored.name == "Alice's iPhone")
        #expect(list.all.count == 2)
        #expect(list.all[0].signerProxy == Self.proxyA)
        #expect(list.all[0].verifiedOnChain == true)
        #expect(list.all[0].pairedAt == again.pairedAt)

        list.remove(Self.proxyA)
        #expect(list.all.map(\.signerProxy) == [Self.proxyB])
        #expect(list.first?.name == "iPhone 2")
        #expect(!list.contains(Self.proxyA))
    }

    @Test func renaming() throws {
        var list = PairedSigners()
        try list.add(Self.signer(Self.proxyA))
        try list.add(Self.signer(Self.proxyB))
        #expect(list.rename(Self.proxyB, to: "  ") == .empty)
        #expect(list.rename(Self.proxyB, to: "IPHONE") == .taken)
        #expect(list.rename(Self.proxyB, to: "  Backup  ") == nil)
        #expect(list.signer(Self.proxyB)?.name == "Backup")
        // 改回自己原来的名字（只是大小写不同）不算重名。
        #expect(list.rename(Self.proxyB, to: "backup") == nil)
    }

    @Test func signersInASafeFollowOwnerOrder() throws {
        var list = PairedSigners()
        try list.add(Self.signer(Self.proxyA))
        try list.add(Self.signer(Self.proxyB))
        let eoa = Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!
        #expect(list.inSafe([Self.proxyB, eoa, Self.proxyA]).map(\.signerProxy) == [Self.proxyB, Self.proxyA])
        #expect(list.inSafe([eoa, Self.proxyC]).isEmpty)
        #expect(list.proxies == [Self.proxyA, Self.proxyB])
    }

    /// 存了再读回来一样；没有或读不出来时是空列表。
    @Test func storage() throws {
        var list = PairedSigners()
        try list.add(Self.signer(Self.proxyB))
        try list.add(Self.signer(Self.proxyC))
        #expect(PairedSigners.load(try list.encoded()) == list)
        #expect(PairedSigners.load(nil).isEmpty)
        #expect(PairedSigners.load(Data("garbage".utf8)).isEmpty)
    }

    /// 请求发给 A，扫回来的却是 B 的签名（拿错了手机）：不通过，并且能认出是 B 签的。
    @Test func signatureFromAnotherPairedSignerIsRejected() throws {
        let a = SoftwareSigner(name: "iPhone", proxy: Self.proxyA)
        let b = SoftwareSigner(name: "iPhone 2", proxy: Self.proxyB)
        let pairedA = PairedSigner(a.pairing), pairedB = PairedSigner(b.pairing)
        let request = transferRequest()
        let forA = SignRequestSession(request: request, signer: pairedA, registration: KnownSafes.sepoliaTestSafe)
        let forB = SignRequestSession(request: request, signer: pairedB, registration: KnownSafes.sepoliaTestSafe)

        // B 签发给自己的那份；就算 request-id 被换成 A 的，公钥也对不上。
        var fromB = try b.sign(forB.signRequest)
        fromB.requestID = forA.requestID
        let check = SignatureCheck(fromB, for: forA)
        #expect(!check.passed)
        #expect(check.results[.requestID] == true)
        #expect(check.results[.signatureForThisSafeTx] == false)
        #expect(SignatureCheck.signedBy(fromB, for: forA, among: [pairedA, pairedB]) == pairedB)

        // A 自己的签名照常通过，也不会被认成别的签名器。
        let fromA = try a.sign(forA.signRequest)
        #expect(SignatureCheck(fromA, for: forA).passed)
        #expect(SignatureCheck.signedBy(fromA, for: forA, among: [pairedA, pairedB]) == nil)
    }
}
