# 事实与链上证据

> README 里每条说法的证据：仓库里的文件、测试，或 Sepolia 上的交易。

## 一句话

一台离线的 iPhone，用 Secure Enclave 里**不可导出的 P-256 密钥直接当 Safe owner**，整个系统里没有任何助记词；签名器自己解码交易、判断风险，联网的电脑端只负责搬运，一律不被信任。

## 核心主张和证据

| 主张 | 证据 | 出处 |
|---|---|---|
| iPhone Secure Enclave 的签名能被 Safe 认可，Safe 1.3.0 / 1.4.1 / 1.5.0 都行 | fork 测试覆盖三个版本；真实 Sepolia 上用官方 factory 验签通过 | `docs/webauthn-signature.md`、`contracts/test/` |
| 私钥从不离开 Secure Enclave，没有助记词 | 密钥用 CryptoKit `SecureEnclave.P256` 生成，不可导出，也没有备份种子；丢失时靠多签换掉 | `apps/signer/README.md` |
| 签名器在完全离线的状态下完成了一笔真实交易 | 手机飞行模式、不插线，扫码 → 独立解码 → Face ID 签名 → 回传 → STS → 执行：[0xfb2148df…1252](https://sepolia.etherscan.io/tx/0xfb2148dfb0a8761abedbb0508b2c8d01c98b9ecdc86a55f9f3d325199be21252)（Sepolia，区块 11994432，`ExecutionSuccess`） | Sepolia 交易 |
| 第一笔由 iPhone 签名的 Safe 交易 | [0x1e546e1c…e3d2](https://sepolia.etherscan.io/tx/0x1e546e1c6930f6842370ac2c66270db595a7f2ca7e58c71687cd21294806e3d2)（Sepolia，区块 11991396） | Sepolia 交易；`RoundTripTests.swift` 重新编码这笔交易必须逐字节相同 |
| 桌面端的提交账户（不是 owner）把签齐的交易发上链 | 签名器离线签 #2（0.001 ETH 给测试地址），提交账户 `0xfe5A…9d49` 发出 type-2 交易执行：[0x4437a381…9bf0](https://sepolia.etherscan.io/tx/0x4437a381a766e7936fe1383abebf7734df9242c1dd368f96f13c523d44309bf0)（Sepolia，区块 12004003，gas 102,119，ExecutionSuccess 的 safeTxHash `0x0de5c23c…a969`，退款为 0） | `apps/coordinator/Packages/SubmitterAccount` |
| 在桌面端里创建 Safe，再用新 Safe 完成第一笔交易 | 桌面端用提交账户发一笔 MultiSendCallOnly 交易创建 2-of-2 Safe [0x1483…125D](https://sepolia.etherscan.io/address/0x1483d0260DF983C21B5Faa04Dee6f4d62a87125D)：[0x6c7d09f5…f99f](https://sepolia.etherscan.io/tx/0x6c7d09f5027c0d096fce6cf36dfd429eb868c9b317984b95bde14b2cafb7f99f)（区块 12005014，gas 1,377,157，地址和发送前的 CREATE2 预测一致）。签名器在第一次签名时顺带登记这个 Safe，离线签名后由提交账户执行：[0x03303d3d…909f](https://sepolia.etherscan.io/tx/0x03303d3dd91ae0624a327e1d54251a520f4e04f6dd7e5a9ad32a8188b50d909f)（区块 12005314，gas 200,039，ExecutionSuccess 的 safeTxHash `0xf6e42e4e…4950`，退款为 0） | `apps/coordinator/Packages/CoordinatorKit/Sources/CoordinatorFlow/SafeCreation.swift` |
| 测试 Safe 和签名器合约 | Safe [`0x8ceb01112162b035BE3D38740f8233d28DA0E4a1`](https://sepolia.etherscan.io/address/0x8ceb01112162b035BE3D38740f8233d28DA0E4a1)（2-of-2：iPhone 的签名器合约 + 测试账户）；签名器合约 `0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06`；部署交易 [0xa9e27b58…c7cb](https://sepolia.etherscan.io/tx/0xa9e27b58c413f7a31accb0af43d8a8dca4ec46fcf96a690068982c45f574c7cb) | `contracts/README.md` |
| 主网和 Base 上可以直接用，不用部署任何东西 | passkey 合约和 Safe 各版本合约都已在规范地址上，三条链代码一致；同一把设备密钥在三条链上算出同一个 owner 地址 `0xc8F9…9A06` | `docs/webauthn-signature.md`"规范部署" |
| 签名器自己解码，不信电脑端 | 只接受唯一的规范 JSON，safeTxHash 自己重算；ABI 只接受标准编码；裸哈希、未登记的 Safe 一律拒签 | `docs/decoding.md`、`docs/rules.md` |
| Bybit 那笔攻击交易会被拒签 | 按公开事后分析还原的交易结构（DELEGATECALL 到陌生合约，calldata 伪装成 `transfer`）命中 R01，直接拒签（DELEGATECALL 到 Safe 官方库以外的合约一律拒签）；当年签名人签的是裸哈希，同样的请求也会被直接拒签 | `testvectors/rules/bybit-2025-02-21.json`、`core/Tests/` |
| 地址投毒防护 | 和地址簿首尾相似就判红；越过时要输入两个地址第一处不同的位置；两个地址并排、标出不同字符；所有地址高亮前后各 8 位 | `docs/rules.md` |
| Safe 退款字段被滥用的防护 | `gasPrice` / `baseGas` / `gasToken` / `refundReceiver` 任一不为 0 就拒签（可以借"退款"名义把 Safe 的钱转走） | `docs/rules.md` |
| 签名器不含网络代码 | Release 构建扫描导入符号，没有任何网络相关的链接或导入；联网时（包括插着数据线）直接拒签，Face ID 通过后签名前再查一次 | `apps/signer/scripts/check-no-network.sh`、`apps/signer/README.md` |
| 二维码传输够快 | iPhone 屏幕 → Mac 摄像头：10 KB（34 帧）3.31 秒收齐，一帧没漏 | 实测（iPhone 15 Pro 屏幕 → MacBook 摄像头） |
| 测试规模 | core 152 个测试（含 Blockchain Commons、Keystone 的官方测试数据和随机畸形输入），签名器 32 个，桌面端 109 个，合约 41 个（其中 9 个是要连 RPC 的 fork 测试） | 各目录的测试 |

## 关键数字

- **gas**（Safe 1.4.1，2-of-2 ETH 转账，主网规则）：两个普通账户签名 90,438；普通账户 + iPhone 签名 **112,520**，也就是每个 iPhone owner 多约 **2.2 万 gas**。没有 P-256 预编译的链上约 32 万，所以这条路是在 Fusaka（EIP-7951）之后才变得实用。
- 部署一个签名器合约约 13 万 gas（一次性）。
- P-256 预编译在主网和 Base 上都约 6,900 gas。

出处：`docs/webauthn-signature.md`"Gas"。

## 和现有做法的区别（据我们所知）

- 常见的 iPhone 离线钱包：在软件里生成 secp256k1 种子，用 Secure Enclave 加密存放，签名时私钥会解密到 App 内存里。我们的私钥从不离开 Secure Enclave。
- passkey 钱包（Safe passkey、Coinbase Smart Wallet）：用 iCloud 同步的 passkey，在线使用。我们的是设备绑定、离线的。
- 硬件钱包加 Safe{Wallet}：风险判断一般在在线端（可能被篡改），硬件钱包多半只显示字段。我们把针对 Safe 的风险判断放在离线签名设备上。

## 局限

- 参考实现，没有经过外部审计，不建议用来管理大额资金。
- 不发布安装包，要自己构建；iOS 需要付费开发者账号，每年要联网重装一次。
- 手机是通用设备，系统本身的攻击面比专用硬件钱包大，离线只能缓解。
- 签名器离线，不知道链上的最新状态。登记 Safe 时只能证明它**创建时**的 owner。
- 这一版只有 iPhone 一种签名器，交易的核验只在一台设备上做。

后续计划见 [future-work.md](future-work.md)。
