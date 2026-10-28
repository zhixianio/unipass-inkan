# 桌面端开发说明

构建和使用见 [README.md](README.md)。这里是代码结构、约定、测试和一些设计取舍。代码里桌面端仍叫 Coordinator，签名器叫 Signer。

## 角色

在线端：组交易、显示二维码给离线签名器扫、用 Mac 摄像头扫回签名、写入 Safe Transaction Service（STS）、执行。签名决策上不被信任（签名器独立复核）。

**桌面端不持有任何 Safe owner 的密钥**。它只保管一个**提交账户**：普通 EOA，不是 Safe 的 owner，只放少量 gas，替用户把签齐的交易发上链；私钥在钥匙串里，不做备份。其他 owner 用自己的钱包签同一笔交易（比如在 Safe{Wallet} 里签，桌面端从 STS 读回）；不用 WalletConnect。

## 目录

| 路径 | 内容 |
|---|---|
| `Coordinator/` | SwiftUI App：资产（首页）、发送、签名面板、活动、地址簿、欢迎引导、设置；DEBUG 构建另有攻击演示（`AttackDemoUI.swift`）和开发者窗口（`DeveloperUI.swift`） |
| `Packages/CoordinatorKit/` | 不联网的本地代码。`QRTransport`：摄像头 + Vision 扫码、CoreImage 出码、UR 多帧收发（包装 core 的 UREncoder / URDecoder）；`CoordinatorFlow`：配对记录、`eth-sign-request` 生成、签名校验、本地 Safe 列表（`SafeStore.swift`：每个 Safe 存 `unipass-safe` 的 CBOR）、创建 Safe 的交易编码和添加已有 Safe 的核对（`SafeCreation.swift`，测试向量是 Sepolia 上实际部署测试 Safe 的那笔交易，逐字节一致）、`execTransaction` 编码、发送流程的纯逻辑（资产、金额换算和显示、收款地址校验、地址簿、交易摘要、网络费估算）；`qr-bench`：离线基准、测试 GIF、从截图解码 UR |
| `Packages/CoordinatorNetwork/` | **全部网络代码**。`SafeTransactionService`：STS 客户端（含 `safes/{address}/creation/`）、以太坊 JSON-RPC（只读 + 广播；代码、存储槽、module 列表）、API key（环境变量 / 钥匙串）、交易状态；`sts-probe`：命令行只读探测；`sts-write`：测试网发起提案、追加确认、拼 `signatures`、RPC 核对。core 和签名器永远不依赖它 |
| `Packages/SubmitterAccount/` | 提交账户，独立的包，删掉它和 `Coordinator/SubmitterAccountUI.swift` 即可去掉。EIP-1559 交易的 RLP 编码和签名、钥匙串存储、执行 `execTransaction`、转出余额、换账户。签名白名单（`SigningPolicy`）：只签 Ethereum / Base / Sepolia 上的、对 Safe 列表里的 Safe（按链 + 地址）的 `execTransaction`（白名单跟着列表变）、转出余额（data 为空，gas 正好 21000）、发给 Safe 1.4.1 MultiSendCallOnly 的创建批量（逐项解码，只允许 value 为 0 的 CALL 调 `SafeWebAuthnSignerFactory.createSigner` 和 SafeProxyFactory 1.4.1 的 `createProxyWithNonce`，singleton 必须是官方部署）；gas 和每 gas 价格有硬上限，报价时节点报的 chainId 必须是目标链、小费压在 2 gwei 以内、网络费上限不超过本地估算的 4 倍（数值和理由见 `SigningPolicy.swift`）；执行、创建 Safe、转出余额前显示网络费"大约 / 最多"，确认后才签；私钥这一层只签 type 2 载荷，type-4 交易和 EIP-7702 授权一律拒绝。secp256k1 用 swift-secp256k1 0.23.2（MIT，只链接其中的 C 库 libsecp256k1，不用带构建插件的 Swift 封装）。测试向量来自 `cast mktx`，签出的原始交易逐字节一致 |
| `Config/` | xcconfig、Info.plist、entitlements |
| `project.yml` | XcodeGen 工程定义 |
| `scripts/` | 中英文本的生成和核对、Release 不含攻击演示的核对 |
| `../../design/app-icon/` | 图标源文件和生成脚本 |

依赖方向：`App → CoordinatorKit / CoordinatorNetwork / SubmitterAccount → ../../core（UniPassCore）`。core 只放纯计算代码。

## 界面约定

- 面向用户的名字：UniPass Inkan 桌面端（UniPass Inkan Desktop，菜单栏短名 Inkan），手机端是 UniPass Inkan 签名器（UniPass Inkan Signer）。
- 界面文字不出现 STS、UR、fps、分片、proxy、CREATE2、safeTxHash 这类术语；safeTxHash 的短码叫"交易指纹"。原始字段只在折叠的「技术细节」里。
- 地址一律每 4 位一组完整显示，**前 8 位和后 8 位加粗**（和签名器一致）；一行放不下时用 `0x前8位…后8位`。
- 测试网在侧边栏、首页、核对页、签名面板、交易详情、设置里都有"测试网"标记。
- 余额显示最多 6 位小数、向下取整，完整值放在悬停提示里（`Asset.display(_:fractionDigits:)`）；网络费估算向上取整（`FeeEstimate.rounded`）。

| 页面 | 做什么 | 校验 |
|---|---|---|
| 欢迎引导（第一次打开） | 这是什么 → 配对签名器 → 给提交账户充值 → 创建或添加 Safe（充值在前：创建 Safe 的交易由提交账户付网络费）。走完写 `onboarded.v1`，只看这一个键（配对过但没走完的，下次打开还在引导里，已配对的那台照样显示） | — |
| Safe 列表 | 存在 UserDefaults 的 `safes.v1`（`SafeStore`），侧边栏顶部的 Safe 卡片里切换。只来自创建或添加，不迁移旧版本的数据（没有老用户）；一个 Safe 都没有时主窗口显示"创建或添加" | — |
| 创建 Safe（欢迎引导、Safe 卡片、文件菜单、设置 › 签名器与 Safe） | 名字、网络（Ethereum / Base / Sepolia）、签名人（已配对的签名器必选；另一台签名器扫配对码；普通地址走 EIP-55 校验）、阈值（默认多数，1-of-N 警告）→ 核对页（本机 CREATE2 算出的地址、签名人、阈值、网络费、提交账户余额）→ 提交账户发一笔交易给 MultiSendCallOnly：还没部署的签名器 proxy 各 `createSigner` 一次，再 `createProxyWithNonce(SafeL2 1.4.1, setup, 随机 saltNonce)` → 等收据 → 核对 → 存进列表 → 提示转入资产、在签名器上登记 | 部署前在链上确认 5 个合约都有代码；签名器地址用目标链上的 `getSigner(x, y, verifiers)` 核对；saltNonce 对应的地址已有代码就换一个；发送前过一遍提交账户的白名单；上链后核对代码、`getOwners`（顺序一致）、`getThreshold` |
| 添加已有 Safe | 地址 + 网络 → 交易服务的 `safes/{address}/creation/` 取 factory、singleton、setupData、saltNonce → 本机解 setup（必须能原样编码回去）、CREATE2 重算地址 → 当前状态读两份：区块链节点（owners、阈值、module、guard 槽、fallback handler 槽、singleton 槽）和交易服务的 `safes/{address}/`，两边必须一致（`ExistingSafe.disagreements`）。加进来以后每次刷新都两边复查 module、guard、fallback handler、singleton，和创建时不一样就在首页和活动页显示红色横幅（`ExistingSafe.configurationChanges`；换签名人、改门限不算） | 只收：官方 factory + singleton；setup 没有额外的 to / data；创建后 owners、阈值、fallback handler、singleton 都没变；没有 module 和 guard；已配对的签名器在 owners 里（`ExistingSafe.problem`）。不满足时一句话说明原因，并列出签名人和门限；都满足时也先列出签名人和门限，用户点「添加这个 Safe」才入列。没配对的 owner 数 ≥ 门限（不经过配对的签名器也能动钱，例如 2-of-3 的 Inkan + Ledger + Trezor）时，说明这一点，要勾选确认后才能添加（`ExistingSafe.Review`） |
| 配对签名器（欢迎引导配第一台；之后在「设置 › 签名器与 Safe › 再配对一台签名器…」；创建 Safe 时扫的另一台也自动配对） | 可以配对几台（`PairedSigners`，存 `pairedSigners.v1`）。每台有这台 Mac 上的名字：默认用签名器报的设备名，重名加编号（iPhone、iPhone 2），可以改；同一台再配对只更新它。逐台解除配对，要二次确认。打开即开摄像头，扫签名器的 `unipass-pairing`，链上核对后**直接保存**（不再要求用户逐组比对地址；防偷换公钥由签名器登记 Safe 时检查） | 只保存核对通过的（`PairingCheck`）：factory 和 verifiers 必须是规范值（先查，不联网）；用当前 Safe 所在链的节点（创建 Safe 时是新 Safe 的链）调 `SafeWebAuthnSignerFactory.getSigner(x, y, verifiers)` 核对 proxy 地址，不一致或网络失败都不保存；已配对的 proxy 带着另一把公钥来也不保存；`.biometryCurrentSet` 时提示 |
| 登记 Safe（「设置 › 签名器与 Safe › 在签名器上登记…」，次要入口） | 单独显示 `unipass-safe` 二维码给签名器扫；一般不需要，第一次签名会顺带登记 | 本机先用 core 的 `SafeAddress.verify` 做 CREATE2 核对，再读链上 owners / 门限；界面写明创建参数只能证明**初始** owner |
| 资产（首页） | Safe 名字、地址、网络、门限；签名人列表（签名器显示设备名，其他看地址簿）；ETH + 标签库里这条链的代币（余额为 0 的折叠），不显示法币；「发送」「接收」；有待处理交易时提示 | 余额、owner、门限、nonce 都从链上读 |
| 发送（⌘N） | 选资产 → 收款人（地址簿点选或粘贴，可保存新地址）→ 金额（可用余额、「全部」）→ 核对页（一句话摘要、收款人、网络、需要几个签名、预计网络费、技术细节）→ 签名面板 | 收款地址：EIP-55 校验和、零地址、Safe 自己；金额：格式、小数位、不为 0、不超过 uint256、不超过余额（`CoordinatorFlow/Send.swift`，`SendTests`） |
| 签名面板 | 发给哪一台：这个 Safe 里每一台还没签的已配对签名器各有一个「让 <名字> 签名」按钮（发送的确认页、交易详情、签名面板里签完一台还差签名时），只剩一台就只有它。步骤条：签名器签名 → 收回签名 → 提交 → 上链。动态二维码一律发 `unipass-sign-request`；**摄像头自动打开**，收齐签名码自动核对，通过后自动保存到 STS；之后每 5 秒刷新，签满后「执行」，由提交账户发 `execTransaction`，等收据进块后刷新活动；「其他执行方式」里保留「在 Safe{Wallet} 中执行」 | 收回签名四项全过才保存：request-id 对应；low-s；UV 位；用**请求发给的那一台**的配对公钥 P-256 验签，challenge 用本机重算的 safeTxHash（别的签名器签的通不过；是另一台已配对签名器签的会说出是哪一台） |
| 活动 | 待处理和历史交易：摘要、状态（待签 1/2、可执行、已上链、已被替换）、时间；详情里有谁签了、「让签名器签名」、执行、区块浏览器链接、技术细节。详情页读列表里的最新记录 | STS 返回的每一笔都用 core 本地重算 safeTxHash，对不上的标成"无法核对"，不能签也不能执行；摘要用 core 的 `RiskEngine` 解码；STS 列表比单笔查询慢时不覆盖本地已知的更新状态（`MultisigTransaction.merge`） |
| 地址簿 | 名字 + 地址，只存在这台 Mac 上（UserDefaults） | 签名器有自己的地址簿，签名时以签名器为准 |
| 设置（⌘,） | 通用（网络、语言）/ 签名器与 Safe（配对；Safe 列表、登记、从这台 Mac 移除、创建、添加）/ 提交账户（地址、二维码、余额、转出余额、危险操作区里的更换账户；不提供导出私钥）/ 高级（每条链的区块链节点：留空用 PublicNode 的公共节点，填了先调 `eth_chainId` 核对链 ID、只收 https（本机 localhost 例外），存钥匙串、打码显示；STS API key，可选） | 转出余额：地址做 EIP-55 校验，确认时再显示金额和完整地址 |

## 启动参数（只在 Debug 构建里有效）

| 参数 | 作用 |
|---|---|
| `-InkanDemo YES` | 攻击演示：「窗口 › Attack Demo Presenter」（⌃⌥⌘D）打开讲解窗口，场景在那里选 |
| `-InkanDeveloper YES` | 「开发者」菜单：扫码测试、动态二维码、交易服务三个调试页（开发者窗口），模拟配对（`testvectors/webauthn/device/signer-key.json` 的公钥，没有手机时调界面用），再次显示欢迎引导；以及配对信息、登记参数、测试网执行（`checkSignatures` 预检、`cast send` 命令）里的调试字段 |

不带参数时，Debug 构建的界面和 Release 一样。

## 另一份独立的 App（录屏、从头试）

换一个 Bundle ID 前缀另外构建一份，放在单独的 DerivedData，不用改 `Local.xcconfig`：

```bash
xcodebuild -project UniPassCoordinator.xcodeproj -scheme UniPassCoordinator -configuration Debug -derivedDataPath build/DerivedData-demo -allowProvisioningUpdates BUNDLE_ID_PREFIX=xyz.unipass.demo build
```

Bundle ID 是 `xyz.unipass.demo.coordinator`：沙盒容器（UserDefaults：配对、Safe 列表、地址簿、引导进度）是另一份；钥匙串里的条目（提交账户、STS API key、区块链节点）服务名都带 Bundle ID 前缀（`KeychainNamespace`），两个 App 互相读不到。第一次打开是全新的欢迎引导。

## 攻击演示（只在 DEBUG 构建里）

模拟被篡改的桌面端：发送流程、核对页、签名面板和正常时一模一样（摘要句、收款人、交易指纹都是用户填的那笔），实际发给签名器的请求被换掉（Bybit 式 DELEGATECALL、地址投毒、退款抽干），用来演示签名器自己判红或拒签。演示步骤和预期见 [docs/demo.md](../../docs/demo.md)。

- 只有带 `-InkanDemo YES` 启动时才启用。唯一的入口是讲解窗口：「窗口」菜单里的「Attack Demo Presenter」（⌃⌥⌘D；不用 ⌥⌘D，那是 macOS 自带的程序坞快捷键），这个菜单项只在 `-InkanDemo YES` 时出现。场景在讲解窗口里选，讲解信息（预期、实际发出的请求和指纹）也在这里。主窗口里没有任何痕迹（录屏只录主窗口）；讲解窗口不在启动时恢复。
- 场景逻辑在 `CoordinatorFlow/AttackDemo.swift`，界面在 `AttackDemoUI.swift`（签名面板 `SignPanel.swift` 里篡改请求的几行），都包在 `#if DEBUG` 里；界面文字在单独的字符串表 `AttackDemo.xcstrings`，Release 构建不带（`project.yml` 的 `EXCLUDED_SOURCE_FILE_NAMES`）。
- 攻击演示模式下签名不会保存到交易服务。
- `scripts/check-release-no-attack-demo.sh`：构建 Release，确认二进制的符号和字符串、App 包里都没有攻击演示（类型名、演示用的两个攻击地址、界面文字）；同时用 Debug 构建做对照，确认检查本身能找到它们。

## 中英双语

- 界面文字的 key 是英文原文，译文在 `Coordinator/Localizable.xcstrings`（en + zh-Hans），App 名称和相机说明在 `Coordinator/InfoPlist.xcstrings`。跟随系统语言；也可以在「系统设置 › 通用 › 语言与地区 › 应用程序」里给这个 App 单独选语言。
- `CoordinatorFlow` 里给界面用的文字（四项检查、Face ID 提示）是 `LocalizedStringResource`，在 App 的目录里查译文。
- 构建开了 `SWIFT_EMIT_LOC_STRINGS`，编译器把 `Text`、`LocalizedStringKey`、`String(localized:)` / `L(…)` 里的字面量抽成 key（插值变成 `%@`、`%lld`）。地址、哈希、数字用 `Text(verbatim:)`。
- 新增文字时先构建，再把译文加进 `scripts/zh-Hans.json`（攻击演示的在 `scripts/zh-Hans-attack-demo.json`），跑 `python3 -I apps/coordinator/scripts/build_catalog.py` 重新生成目录。
- **核对**：每个用到的 key 在目录里、两种语言都是 translated、占位符一致、目录里没有多余的 key：

  ```bash
  apps/coordinator/scripts/check-localization.sh
  ```

  这个脚本不签名地构建到单独的 `build/DerivedData-loccheck`，不会覆盖平时运行的那份（被不签名的构建覆盖后，App 读不到自己的沙盒和钥匙串，看起来像没配对）。

## 测试

```bash
swift test --package-path apps/coordinator/Packages/CoordinatorKit
```

```bash
swift test --package-path apps/coordinator/Packages/CoordinatorNetwork
```

```bash
swift test --package-path apps/coordinator/Packages/SubmitterAccount
```

```bash
apps/coordinator/scripts/check-release-no-attack-demo.sh
```

改了界面以后也跑一遍上面的 `check-localization.sh`。

## 相机权限

- `Info.plist` 的 `NSCameraUsageDescription` 写明用途；
- 沙盒 entitlement `com.apple.security.device.camera`（开启 Hardened Runtime 时也用这个 key）；
- 代码里只在第一次开始扫码时调 `AVCaptureDevice.requestAccess`，之后读授权状态，不再弹框。被拒绝时提示去系统设置打开。

## 为什么没有系统 passkey

桌面端不用系统 passkey（iCloud 钥匙串）当 owner，原因：

- passkey 的签名界面就是桌面端自己，系统对话框只显示域名，不显示交易。不可信的一端拿着 owner 钥匙，和"桌面端在签名决策上不被信任"矛盾；
- 默认 2-of-3 里 passkey + 另一个 owner 就能执行，绕开签名器；
- passkey 绑定域名：域名被入侵、XSS、DNS 劫持或域名过期，都会变成能拿到 owner 签名的入口；
- Apple ID 被接管时同理。

## Safe 交易服务（STS）

- 托管版 base URL：`https://api.safe.global/tx-service/<EIP-3770 短名>`，Sepolia 是 `sep`。客户端认识 Ethereum、Sepolia、Base、Optimism（`SafeChain.known`）。
- API key：`Authorization: Bearer <JWT>`，在 developer.safe.global 申请。**不进仓库**：命令行从环境变量 `SAFE_API_KEY` 读；App 里在「设置 › 高级」填入后存进钥匙串（`xyz.unipass.coordinator.safe-api-key`），也可以在 Xcode scheme 里设环境变量。没有 key 也能调，限 2 RPS、每月 5,000 次，客户端自动把请求间隔拉到 0.55 s。
- 路径里的地址必须是 EIP-55 校验和格式，否则 422 `Checksum address validation failed`。
- 用到的接口：`GET /api/v1/about/`、`GET /api/v1/safes/{address}/`、`GET /api/v2/safes/{address}/multisig-transactions/`、`GET /api/v2/multisig-transactions/{safeTxHash}/`、`POST /api/v2/safes/{address}/multisig-transactions/`（发起提案）、`POST /api/v1/multisig-transactions/{safeTxHash}/confirmations/`（追加确认）。v1 的 safes/{address}/multisig-transactions 已标记废弃。
- **合约签名（`CONTRACT_SIGNATURE`）的编码**：提交给 STS 的 `signature` 是"只含这一个 owner 的 Safe `signatures` 字节"：

  ```
  r = owner 地址左补零到 32 字节
  s = 65（uint256，动态部分在这串字节里的偏移）
  v = 0x00
  uint256(len(sig)) ‖ sig
  ```

  `sig` 是交给 owner 合约 `isValidSignature` 的原始字节，对签名器（SafeWebAuthnSignerProxy）来说就是 `abi.encode(authenticatorData, clientDataFields, r, s)`。实现：`STSSignature.contract(owner:signature:)`（内部调 core 的 `SafeSignatures.encode`）。
- 发起提案的 `sender` 必须是 owner 或 delegate，签名必须是 sender 自己的。桌面端不持有 owner 密钥，所以用 owner 的签名作为 sender：**合约 owner（签名器的 proxy）当 sender 已实测可行**（Sepolia 上第一笔 iPhone 签名的交易就是这样提交的）。客户端本地用 core 算 `contractTransactionHash`，不信任 STS 返回的哈希。
- STS 在执行前不返回拼好的 `signatures`：从 `confirmations` 读回后用 `MultisigTransaction.ownerSignatures()` + core 的 `SafeSignatures.encode` 自己拼。

命令行只读探测（对任意公开 Safe，顺便用 core 重算每笔交易的 safeTxHash 对拍）：

```bash
swift run --package-path apps/coordinator/Packages/CoordinatorNetwork sts-probe --chain sep 0xe58bCB89e205f1f2129FAce64EB402D66f848B71
```

> 装了出站防火墙的话，`.build/` 里新编译的命令行程序可能被拦，表现为 `NSURLErrorDomain -1005 The network connection was lost`。App 重新签名后防火墙也可能重新询问；放行之前，App 里所有联网操作都会一直转圈。

## 二维码基准

```bash
swift run -c release --package-path apps/coordinator/Packages/CoordinatorKit qr-bench capacity
```

子命令：`capacity`（单帧容量）、`decode`（模拟拍摄下的识别率和 Vision 耗时）、`transfer`（模拟整段循环播放传输）、`sample`（保存一张模拟画面）、`gif`（生成给手机播放的测试 GIF）、`images`（从截图识别二维码、拼回 UR 并按类型解析，检查 App 实际显示的码）。帧格式和 App 一致：`ur:bytes` 喷泉码多帧。参数见 `Sources/qr-bench/main.swift` 顶部。

**用手机实测**：

```bash
swift run -c release --package-path apps/coordinator/Packages/CoordinatorKit qr-bench gif --bytes 2000 --chunk 200 --fps 8 --out /tmp/ur-2000.gif
```

把 GIF 隔空投送到 iPhone，在「照片」里打开（GIF 会循环播放），亮度调高，对着 Mac 摄像头；开发者窗口的「扫码测试」页显示帧率、识别率、进度，拼完后显示用时，并核对内容是否等于测试数据。反方向（Mac 出码、手机扫）用「动态二维码」页，帧率、分片大小、纠错等级可调。
