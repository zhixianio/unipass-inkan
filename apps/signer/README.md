# UniPass Inkan 签名器（iOS）

**UniPass Inkan 签名器**（UniPass Inkan Signer）是一台一直离线的 iPhone 上的 App：签名密钥在 iPhone 的安全芯片（Secure Enclave）里，作为签名人加进你的 Safe。电脑上的 **UniPass Inkan 桌面端**（UniPass Inkan Desktop）准备交易，签名器扫码后自己解码、自己算出要签的内容、自己检查风险，你用 Face ID 确认后，它把签名显示成二维码给桌面端扫回去。手机和电脑之间只有二维码，没有任何网络连接。

主屏幕图标下面显示短名 **Inkan**，App 里用全名。

**自己构建和安装：看 [BUILDING.md](BUILDING.md)。** 没有 App Store 或 TestFlight 版本，需要用自己的付费 Apple 开发者账号从源码构建。

## 怎么用

1. **生成签名密钥**：首页点"开始"，选 Face ID 设置（见下面的"Face ID 设置"），点底部的"生成签名密钥"。密钥在安全芯片里生成，不能导出。完成页显示签名人地址，并直接带你去和桌面端配对。
2. **和桌面端配对**：首页"与 UniPass Inkan 桌面端配对"显示一个二维码，里面是本机的公钥和签名地址，桌面端扫它。桌面端创建 Safe 时会把这个地址加为签名人。
3. **加入 Safe**：扫桌面端上的 Safe 码，或者直接扫第一笔签名请求（它可以带上 Safe 的信息）。签名器离线核对 Safe 地址，并确认本机是这个 Safe 的签名人，才会加入"我的 Safe"。
4. **签名**：扫签名请求 → 核对交易 → Face ID → 把签名码给桌面端扫。
5. **一直保持离线**：在**设置**里打开飞行模式，并关掉 Wi-Fi 和蓝牙，拔掉数据线。不要用控制中心：控制中心的开关只断开到第二天或重启，之后会自动恢复（[苹果说明](https://support.apple.com/en-us/102412)）；飞行模式本身不关蓝牙，在飞行模式下手动打开过的 Wi-Fi 或蓝牙下次也会保持打开（[苹果说明](https://support.apple.com/en-us/108785)）。只要检测到联网，签名器就不签。

## 界面

### 首页

首页只回答两件事：现在能不能签、下一步做什么。

- **状态**：大图标加一句话。离线时"已离线，可以签名"，并提醒签名器不读取蓝牙状态、请在设置里确认已关闭；Wi-Fi 开着但没连上网络时多一行提醒（它随时可能自动连上）。联网时"已联网，不能签名"，下面列出还连着的连接和怎么断开（Wi-Fi、蜂窝数据、数据线）。"联网详情"里是每种连接的状态和触发联网的网卡地址。
- **下一步**：还没有密钥时是"生成签名密钥"；有了密钥是醒目的"扫描二维码"按钮；还没有加入任何 Safe 时，多一张"下一步：与桌面端配对"的卡片。有密钥条目却读不出来时（例如锁屏时被预热启动）只有"重试"，不给"生成签名密钥"：已有条目时生成会被拒绝，绝不覆盖。
- 我的 Safe、地址簿（带数量）。
- 右上角齿轮进设置。

### 设置

- **本机**：密钥在哪（"密钥在本机的安全芯片里，不能导出"）、签名人地址（完整显示，见下面"签名人地址不能收款"）、Face ID 设置（只显示，生成后不能改）、删除签名密钥。删除要两次确认，第二次提醒你先确认每个 Safe 的其他签名人在没有本机时仍够所需的同意人数；密钥不能导出，删除后无法找回；已加入的 Safe 和地址簿会保留。
- **删除读不出的签名密钥**：只在密钥条目读不出来时出现在"本机"里。确认页只写后果（密钥永久消失；它是签名人的 Safe 少了一个签名人，要靠其他签名人换掉；之后生成的新密钥是另一个签名人地址），列出上次读出密钥时记下的签名人地址和签名人里有它的已登记 Safe，不给建议。要输入确认字符（"删除" / DELETE），再通过 Face ID 或锁屏密码验证；删之前会再读一次，这时能读出来就不删。只删钥匙串里这一个条目（包括没有 Face ID 设置字段的旧格式条目），已加入的 Safe 和地址簿保留，删完首页回到"生成签名密钥"。
- **与桌面端配对**：显示配对码和签名人地址。已经有 Safe 之后，配对只在这里。
- **关于**：版本、许可证（Apache-2.0）。设置里没有链接，也没有任何会联网的东西。

### 核对交易

签名器只显示自己从请求里解码、计算出来的内容，不信任桌面端给的任何说明。从上到下：

1. **结论**：一行带底色，未发现问题 / 请仔细核对 / 高风险 / 拒签。
2. **这笔交易做什么**：
   - 简单转账（转 ETH，或从 Safe 转出代币）只显示大号金额和收款人。代币不在内置列表里时另外显示代币合约。
   - 其它调用（授权、批量、DELEGATECALL、改 Safe 配置、未知调用）显示一句说明、目标、对方地址和金额。DELEGATECALL 用红色大字标出。
   - 改签名人或所需同意人数时，并排显示变更前后（以这个 Safe 加入本机时记录的签名人为准），并警告"必须所有签名人都同意""任何一个签名人单独就能动用资产""本机将不再是签名人"等情况。
   - 第一次出现的地址可以直接"加入地址簿"，加完重新检查一遍。
3. **风险检查**：每条以规则编号开头（R01、R05……），规则说明见 [docs/rules.md](../../docs/rules.md)。
4. **交易**：Safe（名字和短地址）、网络（例如"Sepolia（测试网）"）、交易指纹（短码，和桌面端签名面板上的写法一样）。"技术细节"默认收起，里面是 Safe 的完整地址、nonce、非 0 的 safeTxGas 和完整的交易指纹。
5. **签名按钮**固定在屏幕下方，不可用时上面写明原因（要先断网，或要先输入确认短语）。拒签时这一页只有原因和交易信息，没有任何签名控件，也没有越过的办法。

**地址显示**：要核对的地址（收款人、被授权方等对方地址，新签名人，加入 Safe 时的签名人和 Safe 地址，本机签名地址）完整显示，不截断；EIP-55 大小写不变，每 4 位一组，前后各 8 位（首尾各两组）加粗。只核对前后各 4 位的仿冒地址很容易算出来，前后各 8 位算不出来。其它地方（目标合约、代币、我的 Safe、地址簿列表）只显示名字和前后各 8 位的短地址（`0x5A0b54D5…3E029c4c`），句子里的短地址也是这样。

**签名人地址不能收款**：本机的签名人地址是 Safe 的签名人合约（WebAuthn signer proxy），不是钱包，没有提款功能，转进去的资产永久取不回来。凡是完整显示它的地方（设置 › 本机、配对页），"签名人地址"旁边都常驻一个橙色小标"请勿转入资产"，而且不能选中复制。规则层也会硬拒任何把资产转给它的交易（[docs/rules.md](../../docs/rules.md) "转给签名人地址"）。

**交易指纹**：要签的哈希（safeTxHash）的前 8 位和后 8 位，例如 `8690 8bd4 … eb94 616d`。只是显示，不要求你和桌面端比对：安全靠的是签名器自己对交易的说明。

**用词**：和桌面端一致，签名器、桌面端、签名人、所需同意人数（"2 个签名人中任意 2 个同意即可"）、交易指纹、网络。

### 高风险时的确认短语

高风险时要输入**每条红色检查项所指对象的后 4 位**，空格分隔，顺序和大小写不限（可以带 0x）。这样你必须真的去看那个有风险的地址，而不是输入一句固定的"我确认"。所指对象：

| 规则 | 要输入的 |
|---|---|
| R01 | DELEGATECALL 目标地址的后 4 位 |
| R02 | 新签名人 / 被移除的签名人 / 模块 / 守卫 / 回退合约地址的后 4 位；改所需同意人数时是新的数字；不认识的 Safe 自身调用是函数选择器的后 4 位 |
| R03 | 被授权方地址的后 4 位 |
| R05 | 见下面 |
| R09（红色） | 代币合约地址的后 4 位 |

同一个值只要输一次；R08 只是汇总，不单独要求。高风险但没有可引用的对象时，改为输入规则编号，不允许空输入通过。页面上逐项写明每一项要输什么，但不直接给出答案。

**R05（地址投毒）例外**：投毒地址就是照着你认识的地址的首尾伪造的，后 4 位和真地址一模一样，输后 4 位说明不了你分得清两个地址。所以要输的是两个地址**第一处不同的位置**开始的 4 个字符（页面写明"0x 之后第 N 位开始"；离末尾不足 4 位时往前挪，始终包含那个不同的字符）。命中 R05 的地址不加粗首尾，而是和地址簿里相似的地址并排显示，不同的字符红色加粗。

## 安全设计

### 联网就不签

签名器每秒用 `getifaddrs` 读一次网卡地址，点签名时在 Face ID 之后、调用安全芯片之前再读一次。不用 Network 框架，App 不链接任何网络库（见"无网络检查"）。

`OfflineCheck.evaluate(_:)` 的规则：

- 只看 `en*`（Wi-Fi、有线、USB 网卡）和 `pdp_ip*`（蜂窝）。`lo0`、`utun*`、`awdl*`、`llw*`、`ipsec*`、`anpi*` 等忽略。
- 这些接口上有任何**不是**回环（`127/8`、`::1`）、未指定（`0.0.0.0`、`::`）、IPv6 链路本地（`fe80::/10`）的地址，就算联网。
- IPv4 链路本地 `169.254/16` **算联网**：iOS 只有在真的接上某个链路但没拿到 DHCP 地址时才分配它，说明射频开着且接上了；而 `fe80::` 在接口没有任何连接时也会挂着，所以只排除 IPv6 的链路本地。
- `getifaddrs` 失败按联网处理。

首页的"Wi-Fi 开着但没连上"提醒按 `en0` 上是否还挂着任何地址（哪怕只有 `fe80::`）判断，只是提示，不影响能不能签。实测关掉 Wi-Fi 时 `en0` 上没有任何地址；Wi-Fi 开着但没连上时 `en0` 是否一定有 `fe80::`，还没在真机上确认。

界面上按连接类型显示：`en0` → Wi-Fi，`pdp_ip*` → 蜂窝数据，其它 `en*` → 数据线或转接头，读不出接口 → 未知。蓝牙不改变任何网卡地址。签名器**不读取蓝牙状态**：读开关要链接 CoreBluetooth，而 CoreBluetooth 也能扫描、广播和建立连接，签名器不带任何能通信的框架（无网络检查把它列为禁止项），所以蓝牙靠你自己在设置里关。没连上网络的 Wi-Fi 也要关，它随时可能自动连上已知网络。

### 签名入口

界面上不显示按钮不是唯一的防线：

1. 只有 core 的 `SignableTransaction(assessment, confirmation:)` 能构造出可签的交易：拒签的检查结果构造失败（即使里面带着请求）；必须有 request-id；高风险必须带正确的确认短语。测试里伪造了一个带请求的拒签结果去签，必须失败（`SigningGateTests.rejectedAssessmentCannotBeSigned`）。
2. 要签的内容取自签名器自己重算出的 safeTxHash，不取请求里的任何其它字段。
3. `TransactionSigner.sign`：先 Face ID，通过后再查一次联网（你可能在核对页停留时打开了 Wi-Fi），然后用同一个已认证的 `LAContext` 调安全芯片（不会弹第二次）。测试验证了顺序和联网时拒绝。
4. 请求必须是发给**这台**签名器的（derivation path 里的密钥指纹、带了地址时的签名地址都要对上），否则拒签。
5. 签名结果是 `unipass-signature` 二维码（[docs/ur-types.md](../../docs/ur-types.md)），request-id 原样带回。

### 签名格式

按 [docs/webauthn-signature.md](../../docs/webauthn-signature.md)：签名器是 Safe 的 WebAuthn 签名人（P-256），由 core 拼出 `authenticatorData`（rpId `unipass.xyz`）和 `clientDataJSON`，消息交给 CryptoKit 签名，结果规范化为 low-s 后 ABI 编码。合约不拒绝 high-s，所以签名器的 low-s 规范化必须保留。

安全芯片密钥：`SecureEnclave.P256.Signing.PrivateKey`，访问控制是"设置了锁屏密码才可用、仅限本机" + 用户选的 Face ID 设置。密钥的加密表示存在 Keychain（不同步、不进备份）。没有锁屏密码时生成密钥会失败，这是预期行为。

### Face ID 设置

生成密钥前选择，之后不能修改；要换只能生成新密钥（新的签名地址，要在 Safe 里重新加为签名人）。选择页**不推荐、不预选**任何一项，选了之后"生成签名密钥"才能点。每个选项只写一句取舍：

- **只认现在录入的面容**：更安全，别人加了自己的脸也签不了；代价是面容录入一变，密钥永久失效，丢失风险更大。
- **任意已录入的面容**：面容变了照样能用；代价是知道锁屏密码的人可以加上自己的脸来签。

页面底部提醒打开 iPhone 的"失窃设备保护"。下表是细节。

| | 任意已录入的面容（`.biometryAny`） | 仅限现在录入的面容（`.biometryCurrentSet`） |
|---|---|---|
| 行为 | 任何已录入的面容都能签；Face ID 录入变化后仍可用 | 只认生成时已录入的面容；录入一变（新增备用外貌、重置面容 ID、系统要求重录）密钥**永久失效** |
| 能防住 | 拿到手机但不知道锁屏密码的人 | 还能防住知道锁屏密码、往设置里加了自己面容的人 |
| 风险 | 知道锁屏密码的人可以加入自己的面容，然后签名 | 失效后本机不能再签，必须由其他签名人移除换新；剩下的签名人凑不够所需的同意人数时资产被锁 |
| 适合 | 密码只有自己知道；不想因重录 Face ID 丢密钥 | Safe 里有足够的其他签名人可以随时换掉本机；更担心"知道密码的人" |

两种都要求设置锁屏密码；只能用 Face ID 签，不能用密码代替；密钥不能导出、不进备份，抹掉或换手机即丢失，所以 Safe 里一定要有其他签名人。`.biometryCurrentSet` 的密钥失效时，系统只报一个笼统的错误，签名器会把它翻译成"这把密钥已经失效：生成它之后 Face ID 的录入变了……"。界面不推荐、不预选，用户选了一项才能生成，并提醒打开"失窃设备保护"。

### 本地数据

"我的 Safe"和地址簿存在 Application Support 里的一个 JSON 文件：原子写入，锁屏时不可读（`NSFileProtectionComplete`），排除出备份。数据量很小，一个 JSON 文件最容易审计；不用 SwiftData / Core Data，因为它们带着同步机制。

- **我的 Safe**：只能通过加入的流程进来。用 CREATE2 按创建参数离线重算地址（只认 Safe 官方的工厂合约和实现合约），并确认本机是签名人；地址对不上、不是官方部署或本机不是签名人，都直接拒绝。加入页写明：这只能证明 Safe **创建时**的签名人和所需同意人数，之后的修改签名器不知道。
- **第一次签名时加入**：扫到带 Safe 信息的签名请求（`unipass-sign-request`）时，Safe 已加入就忽略那部分；没加入、且请求签的正是这个 Safe，就先做上面的核对，显示"首次见到这个 Safe"，你确认后加入，再进入核对交易页。其它情况只看请求本身，不在"我的 Safe"里的 Safe 一律拒签。
- **地址簿**：新地址只有在核对页上你确认、起名之后才会加入；可以删除。

### 无网络检查

```bash
apps/signer/scripts/check-no-network.sh
```

不带参数时生成工程、构建 **Release、generic iOS、不签名**，然后检查；也可以传一个 `.app` 或单个 Mach-O。`--self-test` 会编译一个故意联网的小程序和一个干净的小程序，确认检查能拦下前者、放过后者。发现问题退出码 1，构建失败退出码 2。

检查 `.app` 里的每个 Mach-O：

| 项 | 拒绝 |
|---|---|
| 链接的库（`otool -L`） | `CFNetwork`、`Network`、`NetworkExtension`、`libnetwork`、`WebKit`、`SafariServices`、`MultipeerConnectivity`、`CoreBluetooth`、`CloudKit`、`GameKit`、`NearbyInteraction` |
| 未定义符号（`nm -u`） | `_nw_*`；BSD socket（`socket`、`connect`、`send*`、`recv*`、`getaddrinfo`、`gethostbyname*` 等）；`dlopen`；`DNSService*`；`CFHTTP*`、`CFHost*`、`CFNetService*`、`CFSocket*`、`CFStreamCreatePairWithSocket`；ObjC 类 `NSURLSession*`、`NSURLConnection`、`NSURLRequest`、`NSNetService`、`NSStream` 系列 |
| Swift 符号（demangle 后） | `URLSession`、`URLRequest`、`NWConnection` 等 `NW*`，以及 `init(contentsOf: URL)`（遇到 http URL 会联网；读本地文件请用 path 版本） |
| 字符串 | `NSURLSession`、`nw_connection`、`CFNetwork`、`dataWithContentsOfURL` 等（防按名字动态取类或函数） |

看到但**不是问题**的符号：

- `_getifaddrs`、`_freeifaddrs`、`_inet_pton`、`_inet_ntop`：联网检查本身，只读接口列表、转换地址格式，不收发数据。
- `_dlsym`、`_fopen`、`_fread`、`_sscanf`：来自编译器运行时（`if #available` 的实现）。没有 `dlopen`，所以没列入拒绝名单。
- Foundation / UIKit / SwiftUI 这些系统框架自己包含 URLSession 并间接链接 CFNetwork。这是系统的一部分，检查不了；能保证的是 App 自己的代码没有引用它们。真正的防线是三层："代码不引用" + "飞行模式" + "联网就拒签"。

检查不到的：运行时拼出名字再动态调用（`dlsym` 因编译器运行时而放行）、系统框架内部的联网。所以新增 import 时要在 review 里看一眼。Debug 构建过不了这个检查（Xcode 的 debug-dylib 模式用 `dlopen` 加载主程序），应该检查 Release。

## 开发

### 目录

| 路径 | 内容 |
|---|---|
| `project.yml` | XcodeGen 工程描述（`Signer.xcodeproj` 由它生成，不提交） |
| `Config/` | Team ID 和 Bundle ID（`Signer.xcconfig` + 自己的 `Local.xcconfig`，见 BUILDING.md） |
| `Signer/AppModel.swift` | App 状态：密钥、联网轮询、本地数据；扫码后分流；签名入口 |
| `Signer/HomeView.swift`、`SettingsView.swift`、`ScanView.swift`、`ConfirmView.swift`、`OtherViews.swift`、`PolicyPicker.swift`、`Components.swift` | 首页、设置、扫码、核对交易 / 拒签、签名结果 / 加入 Safe / 我的 Safe / 地址簿 / 配对、Face ID 设置、地址显示等组件 |
| `Signer/Localizable.xcstrings`、`Signer/InfoPlist.xcstrings` | 界面文字、App 名和权限说明（英文、简体中文）；交易说明和规则文字在 core 的 String Catalog 里 |
| `Signer/DemoScenarios.swift` | 只在 DEBUG 构建里：演示场景 |
| `SignerKit/` | 本地 Swift package，依赖 `../../../core`（解码、规则、二维码格式都在 core） |
| `SignerKit/Sources/SignerKit/TransactionSigner.swift` | 签名：只接受 `SignableTransaction`；Face ID → 再查联网 → 安全芯片 |
| `SignerKit/Sources/SignerKit/SignerProxy.swift` | 离线算本机的签名地址（WebAuthn signer proxy）、配对数据。内置的字节码来自 safe-modules，这个文件沿用 LGPL-3.0-only（见 NOTICE），所以不放进 core |
| `SignerKit/Sources/SignerKit/SignerStore.swift` | "我的 Safe"和地址簿 |
| `SignerKit/Sources/SignerKit/OfflineCheck.swift`、`SigningKey.swift`、`KeyStore.swift`、`QRCode.swift` | 联网判断、安全芯片 / 调试软件密钥、Keychain、二维码 |
| `scripts/check-no-network.sh` | 无网络检查 |
| `scripts/verify-device-signature.py` | 用 OpenSSL（Python `cryptography`）独立复验一份真机签名 |

### 构建和测试

在模拟器上构建：

```bash
cd apps/signer && xcodegen generate
```

```bash
xcodebuild -project apps/signer/Signer.xcodeproj -scheme Signer -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath apps/signer/build/DerivedData build
```

改了 `project.yml` 或增删文件后重新 `xcodegen generate`。真机构建和安装见 [BUILDING.md](BUILDING.md)。

SignerKit 的单元测试（Swift Testing），在 macOS 上跑最快：

```bash
cd apps/signer/SignerKit && swift test
```

也可以在 iOS 模拟器上跑（`Signer` scheme 的 test 动作就是 SignerKitTests）：

```bash
xcodebuild -project apps/signer/Signer.xcodeproj -scheme Signer -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath apps/signer/build/DerivedData test
```

### 模拟器演示和截图

DEBUG 构建支持启动参数 `-demoScenario green|yellow|red|rejected|ownerChange|registration|firstUse|networkOnline|sendToSigner`（`-demoOffline YES` 让首页显示离线状态，再加 `-demoWifiOn YES` 显示"Wi-Fi 开着但没连上"的提醒；只改显示）：用软件密钥加入一个演示 Safe（Sepolia 测试 Safe 的参数，签名人换成本机 + 一个测试账户，地址按 CREATE2 现算），然后直接注入一个签名请求。`firstUse` 注入的是带 Safe 信息的签名请求。

```bash
xcrun simctl launch --terminate-running-process booted xyz.unipass.signer -demoScenario red -AppleLanguages "(zh-Hans)"
```

真机上的 DEBUG 构建（注意 `--`，否则 devicectl 会把参数当成自己的选项）：

```bash
xcrun devicectl device process launch --device <UDID> --terminate-existing <BUNDLE_ID> -- -demoScenario green
```

演示按钮、"忽略联网检查"开关和扫码页的"粘贴 UR"框在 DEBUG 构建里也默认隐藏，加启动参数 `-InkanDemo YES` 才出现。Release 构建里没有这些代码，可以用 `strings` 确认（见 BUILDING.md）。

模拟器上的区别：

- **密钥**：一律用软件密钥，界面上橙色标"软件密钥（仅调试，不是 Secure Enclave）"。iOS 26.5 模拟器上 `SecureEnclave.isAvailable` 返回 true，但带 Face ID 访问控制创建密钥会报 `LAError -1020`，所以模拟器上强制不用安全芯片。软件密钥类型只在模拟器或 DEBUG 下编译。
- **联网**：模拟器和 Mac 共用网卡，所以永远显示联网。演示场景会打开"忽略联网检查"。
- **扫码**：模拟器没有摄像头。

## 已知限制

- 规则说明、交易说明和拒签原因的文字来自 core，其中一部分还在用 owner、门限、链 ID 这些说法，会在 core 里统一改。
- 扫码只能在真机上用（模拟器没有摄像头）；DEBUG 构建加 `-InkanDemo YES` 时扫码页可以粘贴 UR 文本。
- 蜂窝数据和个人热点没有在真机上测过：`pdp_ip*` 在联网检查范围内，热点用的接口要不要加进来还没定。
- 用自己的开发者账号构建时，离线超过 30 天后还能不能启动没有实测过，见 BUILDING.md。
