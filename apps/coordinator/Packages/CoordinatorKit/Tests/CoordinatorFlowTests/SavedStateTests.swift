import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

@Suite struct SavedStateTests {
    /// 每个测试一份空的 UserDefaults。
    static func defaults() -> UserDefaults {
        let name = "SavedStateTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func signer() -> PairedSigner {
        PairedSigner(SoftwareSigner(name: "iPhone", proxy: Address(hex: "0x00000000000000000000000000000000000000B2")!).pairing,
                     verifiedOnChain: true)
    }

    /// 新用户配对完就退出（或者在引导里点了"以后再说"）：下次启动时 Safe 列表还是空的，引导也还没走完。
    /// 以前会把项目自己的 Sepolia 测试 Safe 写进列表，提交账户的白名单也就有了它。
    @Test func pairingWithoutAnySafeAddsNoSafe() throws {
        let d = Self.defaults()
        d.set(try PairedSigners([Self.signer()]).encoded(), forKey: SavedState.pairedSignersKey)
        let s = SavedState.load(d)
        #expect(s.signers.all.count == 1)
        #expect(s.store.safes.isEmpty)
        #expect(!s.onboarded)
        #expect(d.data(forKey: SavedState.safesKey) == nil)
    }

    /// 走完引导的照旧；旧版本只存一台签名器的 `pairedSigner.v1` 不再读。
    @Test func readsOnlyTheCurrentKeys() throws {
        let d = Self.defaults()
        d.set(true, forKey: SavedState.onboardedKey)
        d.set(try JSONEncoder().encode(Self.signer()), forKey: "pairedSigner.v1")
        let s = SavedState.load(d)
        #expect(s.onboarded)
        #expect(s.signers.isEmpty)
        #expect(s.store.safes.isEmpty)
    }
}
