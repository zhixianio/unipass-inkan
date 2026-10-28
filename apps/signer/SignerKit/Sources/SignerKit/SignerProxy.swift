// SPDX-License-Identifier: LGPL-3.0-only
// This file embeds the SafeWebAuthnSignerProxy creation code compiled from safe-modules (LGPL-3.0-only),
// so it keeps the upstream license. The rest of this repository is Apache-2.0; see NOTICE.

import Foundation
import UniPassCore

/// 离线算出这台 Signer 在 Safe 里的 owner 地址：`SafeWebAuthnSignerFactory.getSigner(x, y, verifiers)`。
/// CREATE2，salt 0，init code = `creationCode ‖ uint256(singleton) ‖ x ‖ y ‖ uint256(verifiers)`。
///
/// 常量来自 `contracts/src/PasskeyDeployments.sol`（safe-modules passkey v0.2.1 的规范部署；
/// creationCode 取自规范 factory 运行时代码里内嵌的那段，fork 测试核对过）。这段字节码来自 LGPL-3.0 的
/// safe-modules，所以整个文件沿用上游许可证，单独放在这里，不放进 core（见 NOTICE）。
public enum SignerProxy {
    public static let factory = Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!
    public static let singleton = Address(hex: "0x4E27b51350e6c2083EE19011120F50DAfEc5CA50")!
    /// P256.Verifiers：0x0100 预编译 + FCL 回退验证合约 0x445a…e765（推荐配置）。
    public static let defaultVerifiers = Data(hex: "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")!

    static let creationCode = Data(hex:
        "610100346100ad57601f6101b538819003918201601f19168301916001600160401b038311848410176100b257808492"
        + "6080946040528339810103126100ad578051906001600160a01b03821682036100ad5760208101516040820151606090"
        + "920151926001600160b01b03841684036100ad5760805260a05260c05260e05260405160ec90816100c9823960805181"
        + "6082015260a05181604d015260c051816027015260e0518160010152f35b600080fd5b634e487b7160e01b6000526041"
        + "60045260246000fdfe7f000000000000000000000000000000000000000000000000000000000000000060b63601527f"
        + "000000000000000000000000000000000000000000000000000000000000000060a03601527f00000000000000000000"
        + "0000000000000000000000000000000000000000000036608001523660006080376000806056360160807f0000000000"
        + "0000000000000000000000000000000000000000000000000000005af43d600060803e60b1573d6080fd5b3d6080f3fe"
        + "a26469706673582212201660515548d15702d720bbc046b457ca85e941a4559ab9f9518488e4c82e5ee964736f6c6343"
        + "00081a0033")!

    public static func address(x: Data, y: Data, verifiers: Data = defaultVerifiers) -> Address {
        precondition(x.count == 32 && y.count == 32 && verifiers.count == 22)
        let initCode = creationCode + singleton.abiEncoded + x + y + Data(count: 10) + verifiers
        let h = Keccak.hash256(Data([0xFF]) + factory.bytes + Data(count: 32) + Keccak.hash256(initCode))
        return Address(bytes: Data(h.suffix(20)))!
    }

    /// 配对二维码（`unipass-pairing`）。
    public static func pairing(key: some P256SigningKey, name: String, policy: BiometryPolicy?) -> SignerPairing {
        let xy = key.publicKeyXY
        return SignerPairing(x: xy.x, y: xy.y, name: name,
                             biometryPolicy: policy.map { $0 == .anyEnrolled ? .anyEnrolled : .currentSet },
                             signerProxy: address(x: xy.x, y: xy.y), verifiers: defaultVerifiers, signerFactory: factory)
    }

    /// 发给这台 Signer 的请求应当指向的身份（`RiskContext.signer`）。
    public static func identity(key: some P256SigningKey) -> SignerIdentity {
        let xy = key.publicKeyXY
        return SignerIdentity(keyFingerprint: SignerPairing.keyFingerprint(x: xy.x, y: xy.y), signerProxy: address(x: xy.x, y: xy.y))
    }
}
