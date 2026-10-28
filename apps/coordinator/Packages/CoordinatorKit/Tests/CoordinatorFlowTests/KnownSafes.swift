import Foundation
import UniPassCore

/// 测试用：项目自己的 Sepolia 测试 Safe 的创建参数。App 不认识它，Safe 列表只来自创建或添加（`SafeStore`）。
enum KnownSafes {
    /// contracts/script/DeployTestSafe.s.sol（SAFE_SALT_NONCE 默认 0）：SafeL2 1.4.1，2-of-2，
    /// owners = [Signer 的 WebAuthn proxy, 部署用的测试 EOA]，fallbackHandler = CompatibilityFallbackHandler 1.4.1。
    static let sepoliaTestSafe = SafeRegistration(
        chainID: 11_155_111,
        safe: Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!,
        proxyFactory: Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!,
        singleton: Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!,
        saltNonce: .zero,
        owners: [
            Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!,
            Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!,
        ],
        threshold: 2,
        fallbackHandler: Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!,
        name: "Sepolia test Safe"
    )
}
