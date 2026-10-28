import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

@Suite struct PairingCheckTests {
    static let attacker = Address(hex: "0x00000000000000000000000000000000000000aa")!
    let signer = SoftwareSigner(name: "iPhone")

    /// 规范的 factory 和 verifiers、链上核对一致：可以保存。
    @Test func canonicalAndVerified() {
        let p = signer.pairing
        #expect(PairingCheck.check(p, onChain: p.signerProxy, paired: PairedSigners()) == .ok)
    }

    /// 配对码里的 factory 或 verifiers 不是规范值：不管链上怎么说都不收。攻击者用自己的 factory
    /// 可以让 `getSigner` 返回任意地址（比如他自己的 Safe 里的 owner）。
    @Test func refusesOtherFactoryOrVerifiers() {
        var p = signer.pairing
        p.signerFactory = Self.attacker
        #expect(PairingCheck.check(p, onChain: p.signerProxy, paired: PairedSigners()) == .notCanonical)
        p = signer.pairing
        p.verifiers = Data(hex: "0x0000" + String(repeating: "11", count: 20))!
        #expect(PairingCheck.check(p, onChain: p.signerProxy, paired: PairedSigners()) == .notCanonical)
        #expect(PairingCheck.canonicalVerifiers.hexString == "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")
        #expect(PairingCheck.signerFactory == SafeCreation.signerFactory)
    }

    /// 链上没核对成（网络、节点不支持）：不保存。
    @Test func refusesUnverified() {
        #expect(PairingCheck.check(signer.pairing, onChain: nil, paired: PairedSigners()) == .unverified)
    }

    @Test func refusesMismatch() {
        #expect(PairingCheck.check(signer.pairing, onChain: Self.attacker, paired: PairedSigners()) == .mismatch(onChain: Self.attacker))
    }

    /// 已经配对过的 proxy 带着另一把公钥来：不覆盖。同一把公钥再配对照常。
    @Test func refusesANewKeyForAPairedProxy() throws {
        var list = PairedSigners()
        try list.add(PairedSigner(signer.pairing, verifiedOnChain: true))
        let impostor = SoftwareSigner(name: "Evil", proxy: signer.proxy).pairing
        #expect(PairingCheck.check(impostor, onChain: impostor.signerProxy, paired: list) == .keyChanged)
        #expect(PairingCheck.check(signer.pairing, onChain: signer.proxy, paired: list) == .ok)

        // 列表本身也不让换：抛错，原来那条不变。
        #expect(throws: PairedSigners.KeyChanged.self) { try list.add(PairedSigner(impostor, verifiedOnChain: true)) }
        #expect(list.all.count == 1)
        #expect(list.all[0].x == signer.pairing.x && list.all[0].name == "iPhone")
    }
}
