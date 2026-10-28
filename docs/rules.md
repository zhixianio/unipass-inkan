# 规则与白话解释（L1）

> 实现在 `core/Sources/UniPassCore/Rules/`，模板和标签库在 `core/Sources/UniPassCore/Resources/`，测试在 `core/Tests/UniPassCoreTests/RulesTests.swift`。

## 输入与输出

```
RiskEngine(context:).assess(signRequest: / ur: / SafeTxRequest) → RiskAssessment
```

**输入**（`RiskContext`）：

| 字段 | 内容 |
|---|---|
| `mySafes` | "我的 Safe"：链 + 地址 + 名字（登记流程用 `unipass-safe`） |
| `addressBook` | Signer 上的地址簿（名字是外部字符串） |
| `labels` | 内置标签库，默认 `LabelLibrary.builtIn` |
| `networkOnline` | R11：调用方（Signer 的 `getifaddrs` 检查）传入 |

**输出**（`RiskAssessment`，确认页直接用，不再自己解析）：

| 字段 | 内容 |
|---|---|
| `request` | 链、Safe、SafeTx、重算的 safeTxHash、nonce（解析失败时为 nil） |
| `actions` | 展开后的每条调用：在 MultiSend 里的位置、operation、目标地址和标签、随带的原生币、结构化的动作（收款人、金额和代币、授权对象、owner 变更……）、白话说明、该条的风险等级 |
| `findings` | 可越过的发现项：规则 id、黄 / 红、位置、白话说明 |
| `rejections` | 硬拒原因：和 `findings` 是**不同的类型**，没有越过的入口 |
| `verdict` | `green` / `yellow` / `red`（可越过，要输入确认短语）/ `rejected`（硬拒） |

## 硬拒

| 原因 | 说明 |
|---|---|
| 请求解析失败 | UR、`eth-sign-request`、EIP-712 JSON 任何一处不合规 |
| 裸哈希 | personal_sign 的 32 字节数据。Bybit 的签名人签的就是裸哈希（见下文） |
| 不是 SafeTx | data-type 不是 2。v1 只签 Safe 交易 |
| 链不在首发范围 | 1、8453、11155111 之外 |
| **Safe 不在"我的 Safe"里** | **硬拒，不能越过。** 有正规的登记流程（`unipass-safe`，Signer 用 CREATE2 离线核对地址），没必要留越过的口子；否则 Coordinator 被控制时可以引导用户签别人的 Safe。同一个地址登记在别的链上也不算 |
| 解码问题 | 参数编码不规范、MultiSend 数据截断或多余、用 CALL 调 MultiSend、内部 operation 无效、MultiSendCallOnly 里有 DELEGATECALL、嵌套过深、调用过多——每一种都映射为硬拒（`everyDecodingProblemRejects` 逐一覆盖） |
| R11 联网 | 签名时 Wi-Fi / 蜂窝接口有可路由地址 |
| **gas 退款**（`gasRefundNotSupported`） | `gasPrice`、`baseGas` 不为 0，或 `gasToken`、`refundReceiver` 不是零地址。v1 不用 Safe 的退款机制，执行一律由执行者自己出 gas。见下文"gas 与退款" |
| **转给签名人地址**（`sendsToSignerAddress`） | 交易会把资产转给这台签名器自己的 signer proxy（`RiskContext.signer.signerProxy`）：SafeTx 或 MultiSend 里任何一条调用的 `to` 是它且带 ETH；ERC-20 `transfer` / `transferFrom` 或 NFT 转账的收款方是它。见下文"转给签名人地址" |
| **对方是 Safe 系统合约**（`counterpartyIsSafeContract`） | 收款人、授权对象（增加授权时）、operator（授权时）、新 owner，或带 ETH 调用的合约，是 Safe 的 singleton、proxy factory、fallback handler、库合约（MultiSend、MultiSendCallOnly、SignMessageLib、CreateCall、迁移合约等）、WebAuthn signer factory，或 Permit2。唯一例外：ERC-20 `approve` / `increaseAllowance` 给 Permit2 是 Permit2 的正常用法。见下文"对方是 Safe 系统合约" |
| **DELEGATECALL 到不允许的合约**（`delegateCallNotAllowed`） | 目标不是官方 MultiSend / MultiSendCallOnly，也不是 R01 那几个官方升级 / 部署库。被调用的代码以 Safe 的身份运行，能改它的存储（Bybit 就是这样被换掉实现合约的），正常使用完全不会出现（2026-10-28 用户决定：正常使用不会出现的就拒签）。其余 Safe 官方库也在这里：SignMessageLib 让 Safe 认可一个签名器解读不了的消息哈希，等于盲签，和裸哈希一样拒；SafeToL2Setup 只在创建 Safe 时用；SimulateTxAccessor 只用于模拟 |

## 确认短语

越过红色时要输入的字符（`ConfirmationPhrase`）：每条红色发现项"关于"的那个东西的 4 位，空格分隔，顺序和大小写不限。地址取后 4 位，门限取整个数字，选择器取后 4 位，R05 取两个地址第一处不同的位置开始的 4 位；R08 只是汇总，不单独要求。

**按（规则、位置、对象）去重，不按字符串值去重。** 两条红色要求的字符撞了（例如 DELEGATECALL 目标的后 4 位刻意和无限授权对象的后 4 位相同，或者同一个地址被两条规则标红），后来的一条换同一地址的另一个 4 位窗口（`addressWindow`，往前每 4 位一个），确认页写明从第几位开始；门限或选择器撞了时输入"规则号-序号"（例如 `R02-2`）。这样每条红色都要单独输入，输一次不能同时放过两条（安全核查 P2-4）。

## 规则

| id | 级别 | 条件 | 备注 |
|---|---|---|---|
| R01 | 红 | DELEGATECALL 到 Safe 官方的升级 / 部署库：SafeMigration（1.4.1、1.5.0）、SafeToL2Migration（1.4.1）、CreateCall（1.3.0 两份、1.4.1、1.5.0），即 `SafeDeployments.delegateCallLibraries` | 升级 Safe 版本、从 Safe 部署合约少见但正当，可能由其他签名人在 Safe{Wallet} 里发起、经桌面端从交易服务取来，所以判红、可输入确认字符越过；SafeMigration 会换掉 Safe 的实现合约，不能悄悄放过。DELEGATECALL 到官方 MultiSend / MultiSendCallOnly 不判；**到其它任何合约直接拒签**，见"硬拒" |
| R02 | 红 | `to == 这个 Safe` 的 owner / 门限 / 模块 / 守卫 / 模块守卫 / 回退处理合约变更 | **另外：对 Safe 自身的任何不认识的调用也判红**（例如 `approveHash` 能替别的交易预先批准）。**嵌套 Safe**（`rule.R02.mySafeCall` / `rule.R02.safeFunction`）：带调用数据地调用"我的 Safe"里任何一个 Safe（包括这个 Safe 自己的 `approve` 之类"任何合约都适用"的函数），或者对任何地址调用 Safe 的管理 / 执行类函数（`addOwnerWithThreshold`、`removeOwner`、`swapOwner`、`changeThreshold`、`enableModule`、`disableModule`、`setGuard`、`setModuleGuard`、`setFallbackHandler`、`approveHash`、`execTransaction`、`execTransactionFromModule(ReturnData)`、`setup`，`Selectors.safeManagement`），也判红：目标可能是另一个 Safe，这些调用能改它的签名人、替它批准或执行交易。`execTransaction` 的内层不解码，一律判红。单纯往自己的别的 Safe 转 ETH 不算。确认页对 owner 变更显示前后对比 |
| R03 | 红 | ERC-20 `approve` / `increaseAllowance`（及别名）数量"接近无限"；`setApprovalForAll(…, true)`（及 ERC-777 `authorizeOperator`）；Permit2 `approve` 数量"接近无限" | "接近无限"（`RiskEngine.isUnlimited`）：**有 decimals 时 ≥ 10^(decimals+9)**，即 10 亿个代币；**没有 decimals 时 ≥ 2⁹⁶**（18 位小数时约 790 亿个）。以前按原始整数 2¹²⁸ 判，对 6 位小数的 USDC，2¹²⁸−1 是 3.4×10³² 个，实际就是无限，却只判黄。常见的"无限"写法（2²⁵⁶−1、2²⁵⁵、2¹⁶⁰−1、2¹²⁸−1）都在两个阈值之上。**有限的授权**：对方在地址簿或"我的 Safe"里时不判；不在时由 R06 判黄，说明里写出金额；对方是代币合约或 Safe 系统合约时见 R13 和硬拒。数量为 0 的 approve 是撤销，`decreaseAllowance` 和 `setApprovalForAll(…, false)` 不判 |
| R05 | 红 | 收款人 / 授权对象 / 新 owner 和下面任一个已知地址**开头相同的十六进制位数 + 结尾相同的位数 ≥ 6**（不区分大小写，怎么分都算：3+3、2+8、8+2、6+0……），但不是同一个地址：地址簿（**不按链过滤**）、"我的 Safe"、本机的签名人地址、已登记 Safe 的签名人（登记时记下的 `MySafe.owners`，不要求在地址簿里） | **豁免**（收款人本身算认识的，不报）只认当前链的地址簿条目、当前链的"我的 Safe"和本机签名人地址。已登记 Safe 的 owners 只当比对对象、不当豁免：否则攻击者先诱导用户登记一个 owner 里有仿冒地址的 Safe，就能让这个地址免检；地址簿条目只登记在别的链上时，仿冒它的地址在这条链上照样要比。按"当前链的地址簿、别的链的地址簿、我的 Safe、本机签名人地址、owners"的顺序取第一个相似的已知地址，每个收款人最多报一次（同时在地址簿和 owners 里的，用地址簿里的名字报一次）。相似的是签名人时，说明写出是哪个 Safe 的签名人（`rule.R05.safeOwner`，例如"看起来像 Safe “My Safe” 的签名人 0x9383…B39a"；Safe 没起名字时写 Safe 的短地址），是本机签名人地址时用 `rule.R05.thisSigner`；同一个签名人在几个 Safe 里时，优先写同一条链上的第一个 Safe。常量 `lookalikeMatchChars = 6`。依据：钱包和浏览器缩写地址时显示前后 4–8 位，地址投毒就是生成这几位相同的地址；只仿一端也要抓到（例如只仿后 8 位，正是地址显示时加粗的部分）。两个无关地址碰巧满足的概率约 7×16⁻⁶ ≈ 4×10⁻⁷，已知地址 1000 个时每笔交易误报约 4×10⁻⁴。发现项的 `subject` 是 `.lookalike(地址, similarTo: 已知地址)`；越过时的确认短语取两者**第一处不同的位置**开始的 4 个字符，不取后 4 位（后 4 位可能正是伪造的部分），见 `ConfirmationPhrase.differenceWindow` |
| R06 | 黄 | 收款人 / 授权对象 / 新 owner 不在地址簿、也不是"我的 Safe"。**标签库里的地址不算认识的对方**：标签只说明它是什么合约，不说明可以把资产交给它（库里只有 Safe 系统合约、Permit2 和代币，前两种硬拒，代币判 R13） | 命中 R05 时不再报 R06。确认页上，命中 R05 的地址（包括 MultiSend 内层的）不标"首次出现"、不提供"加入地址簿"，只显示和已知地址的并排对比：把仿冒地址存进地址簿正是投毒想要的结果。判定在 `RiskAssessment.isFirstSeen(_:thisSigner:)`，本机签名人地址同样不提供 |
| R07 | 黄 / 红 | 不认识的函数选择器（或调用数据不足 4 字节） | 目标是 Safe 自己时改判 R02。**目标是标签库里的代币合约时判红**（`rule.R07.token`，确认字符是选择器后 4 位）：库里的代币上不认识的函数，可能是另一种转账或授权写法 |
| R08 | 取子调用最高级 | MultiSend 的子调用（含嵌套）命中 R01–R05 | 只有子调用命中 R01/R02/R03/R05 时才加 R08；R06/R07/R09 的黄不触发 R08（它们本身已经在结果里） |
| R09 | 黄 / 红 | 黄：代币合约不在标签库里（或类型不对，比如对库里的 ERC-20 调 NFT 函数）。红：地址簿给这个陌生合约起的名字和库里某个代币的符号或名称相同（同名不同地址） | 在线摘要（M2）提供的代币名以后也走同一个"同名不同地址"检查 |
| R12 | 黄 | `safeTxGas` 不为 0 | 执行失败时交易仍被记为已执行、nonce 被用掉，拿到签名的人可以故意给不够的 gas 让它失败。不会多转走钱，所以不判红；Coordinator 自己生成的请求填 0（发送流程用 `Transfer.safeTx` 构造，退款相关字段和 safeTxGas 都填 0），出现非 0 说明请求来自别处（例如从 Safe Transaction Service 拉来的交易）或被改过，值得用户注意，所以不只是显示。确认页"交易"部分同时显示它的值。见下文"gas 与退款" |
| R13 | 红 | 收款人 / 授权对象 / operator / 新 owner 是代币合约本身：标签库里的任何代币，或者正在调用的那个代币合约 | 转给代币合约的代币通常永久丢失；授权给代币合约没有正当用途。不硬拒，因为 WETH 这类合约收 ETH 是"包装"，用户核对后可以输入确认字符越过。命中 R13 时不再报 R05 / R06 |

**代币的别名函数**：下面这些函数和标准函数做同样的事，解码后映射到同样的动作，所以同样走 R03、R05、R13 和"转给签名人地址"的硬拒：

| 函数 | 当作 |
|---|---|
| `increaseApproval` / `decreaseApproval`（旧版 OpenZeppelin、LINK） | `increaseAllowance` / `decreaseAllowance` |
| `approveAndCall(address,uint256)` / `approveAndCall(address,uint256,bytes)`（ERC-1363） | `approve` |
| `transferAndCall(address,uint256)` / `transferAndCall(address,uint256,bytes)`（ERC-677、ERC-1363） | `transfer` |
| DAI `push(usr, wad)` / `move(src, dst, wad)` | `transfer` / `transferFrom` |
| DAI `pull(usr, wad)` | 从 usr 转到这个 Safe |
| ERC-777 `authorizeOperator` / `revokeOperator` | `setApprovalForAll(…, true / false)` |
| ERC-1155 `safeBatchTransferFrom` | NFT 转出，逐项列出 id × 数量 |
| stETH `transferShares` / `transferSharesFrom` | 代币转出；数量是份额，不按 decimals 换算，说明里写明 |

这些选择器对任何合约都识别（不限于库里的代币），不在库里的合约同时报 R09。

**`transferFrom(address,address,uint256)`**（ERC-20 和 ERC-721 共用一个选择器）：库里的 ERC-20 按数量解释；库里的 NFT 合约按 tokenId 解释；不认识的合约不解释成数量，说明写"未知合约的 transferFrom"，同时照常走 R09（黄）。

R04（Permit / Seaport 消息签名）和 R10（在线摘要不一致）不在 M1：消息签名是 v1.1，摘要帧是 M2。

## gas 与退款

SafeTx 里有五个和 gas 有关的字段：`safeTxGas`、`baseGas`、`gasPrice`、`gasToken`、`refundReceiver`。它们都进 safeTxHash，签了就认。`execTransaction` 里的相关逻辑在 Safe 1.3.0（`GnosisSafe.sol`）、1.4.1、1.5.0（`Safe.sol`）三个版本里一样（核对的是 safe-smart-account 各版本 tag 的源码；1.5.0 把 `require` 换成了 `revertWithError` 和带返回数据的 `revert`，语义不变）：

1. 先检查 `gasleft() >= max(safeTxGas × 64 / 63, safeTxGas + 2500) + 500`，否则 `GS010`。
2. 内部调用拿到的 gas：`gasPrice == 0` 时是 `gasleft() − 2500`（**不受 safeTxGas 限制**），否则正好是 `safeTxGas`。
3. 内部调用失败时：只有 `safeTxGas == 0 且 gasPrice == 0` 才让整笔回滚（`GS013`）；否则 execTransaction 成功，发 `ExecutionFailure`，**nonce 照样加 1**。
4. `gasPrice > 0` 时调 `handlePayment`：金额 `(gasUsed + baseGas) × gasPrice`（用 ETH 时 gasPrice 不超过 `tx.gasprice`，用代币时没有这个上限），用 `gasToken`（零地址 = ETH）付给 `refundReceiver`（零地址 = `tx.origin`）。

**退款硬拒的理由**：被控制的 Coordinator 可以让确认页显示"转 25 USDC 给 Alice"，同时把 `gasPrice`、`baseGas` 设得很大、`refundReceiver` 设成攻击者，执行时 Safe 额外"退款"转走大量 ETH 或代币。确认页的白话说明只讲调用本身，所以这几个字段必须由规则拦住。v1 不用退款，没有合法用途，硬拒最简单。`gasPrice == 0` 时合约不会付款，但 `baseGas`、`gasToken`、`refundReceiver` 不为空也拒：没有理由带着它们签名，而且以后改规则时不会留下半开的口子。拒签说明会列出四个字段的值。

**safeTxGas 判黄的理由**：退款被拒以后，`gasPrice` 恒为 0，`safeTxGas` 不再限制内部调用的 gas（第 2 条），它唯一的作用是第 3 条——让失败的交易也算"已执行"。后果是拿到全部签名的人（包括被控制的 Coordinator）可以给刚好过 `GS010` 的 gas，让内部调用耗尽 gas 失败，这笔交易就被"用掉"了，nonce 前进，同 nonce 的其它待签交易作废。这是拒绝服务，不会多转走钱（退款已经拒了），所以不判红；但 Coordinator 自己生成的请求填 0，出现非 0 说明请求来自别处或被改过，判黄让用户看到。Bybit 的那笔交易 `safeTxGas = 45746`，重放时除了 R01 红还会多一条 R12 黄。

## 转给签名人地址

签名器的"签名地址"（配对时给桌面端、在 Safe 里当签名人的那个地址）是 Safe 官方的 WebAuthn signer proxy，只用来验证 P-256 签名，不是钱包：

- 它没有任何提款或转发资产的功能。转进去的 ETH、代币、NFT 永久取不回来。
- 已部署的链上，proxy 收到普通 ETH 转账会回滚，但 ERC-20 的 `transfer` 照样成功（Sepolia 上实测 `0xc8F9…9A06`）。
- 同一个地址在还没部署 proxy 的链上（例如配对后、创建 Safe 之前，或别的链）只是一个空地址，转 ETH 也会成功。

从 Safe 往自己的签名人合约转资产没有任何正当用途，所以硬拒、不留越过的口子；最可能的来源是用户把签名地址误当成收款地址。拒签说明写明"收款地址是这台签名器自己的签名合约，它不能收款，转进去的资产会永久取不回来"。只检查这台签名器自己的地址：别的签名人的地址规则层不知道，它们是不是合约也无法离线判断。签名器界面上凡是完整显示签名地址的地方都常驻提醒"不要往这里转任何资产"，也不提供复制。

## 对方是 Safe 系统合约

Safe 的系统合约是公共基础设施，谁都能调用，不替任何人保管资产：

- MultiSendCallOnly（1.3.0、1.4.1、1.5.0）没有"只能被 DELEGATECALL"的限制。`USDC.approve(MultiSendCallOnly, X)` 签出去以后，任何人都能直接调用它的 `multiSend`，让它执行 `USDC.transferFrom(Safe, 攻击者, X)`。直接转给它的代币和 NFT 同理，任何人都能取走。
- 其它库合约、singleton、proxy factory、fallback handler、WebAuthn signer factory 没有提款功能，转进去就取不回来；授权给它们也没有正当用途。
- Permit2 只在 ERC-20 `approve` / `increaseAllowance` 给它时有意义（之后再用 Permit2 自己的 `approve` 授权具体的对方）。转给 Permit2、把 Permit2 设成 operator 或新 owner、在 Permit2 里授权给 Permit2 都没有正当用途。

所以这些都硬拒，不留越过的口子。判定（`RiskEngine.isSafeContract`）看 `SafeDeployments` 的 MultiSend 表、`SafeAddress` 的 factory / singleton / fallback handler 表、WebAuthn signer factory 常量，以及标签库里 `safe*` 和 `permit2` 类的条目。确认页上这些对方不标"首次出现"、不提供"加入地址簿"。

## 白话解释

- 模板在 `Resources/Localizable.xcstrings`（String Catalog，中英双语），共 59 条；用位置参数（`%1$@`），两种语言可以调换语序。`Explanation` 是"key + 参数"，确认页按用户语言渲染（`render(.simplifiedChinese)` / `render(.english)` / 系统语言）。测试确保源码用到的每个 key 都有两种语言的翻译、渲染后不残留占位符、目录里没有多余的 key。
- **外部字符串只当数据引用**：地址簿名、标签库里的代币名只作为参数插入，加引号，去掉控制字符（Cc）和格式字符（Cf：RLO / LRI 等方向控制符、零宽字符），折叠空白，最多 32 个字符。参数里的 `%` 不会被当成格式（`externalStringsAreSanitized`）。
- 地址在句子里写成 `"标签" (0xAbCd1234…5678EfAb)`，前后各 8 位（前后各 4 位的仿冒地址很容易算出来）；完整地址由确认页另外显示，4 位一组，首尾两组高亮。
- 金额有 decimals 时按小数显示（千分位逗号）；不知道 decimals 时显示原始整数加"最小单位"。
- DELEGATECALL 到 MultiSend 以外的地址时，说明先讲"这个 Safe 会以自己的身份运行目标的代码"，调用数据表面上的解释放在后面——Bybit 的调用数据表面上就是一笔无害的 `transfer`。

## 标签库

`Resources/labels.json`，由 `testvectors/generator/build_labels.py` 生成：

| 内容 | 来源 |
|---|---|
| Safe 官方合约（singleton、proxy factory、fallback handler、MultiSend、CreateCall、SignMessageLib、迁移合约等），v1.3.0 / 1.4.1 / 1.5.0，链 1 / 8453 / 11155111 | safe-global/safe-deployments（MIT）commit `8e200b0`，每条记录对应的 asset 文件 |
| Permit2 | Uniswap/permit2（MIT）`test/utils/DeployPermit2.sol` 的 `PERMIT2_ADDRESS` |
| 代币（27 个：主网 13、Base 11、Sepolia 3） | `testvectors/generator/tokens.json`：每条带发行方官方文档的 URL 和原文摘录，拿不准的不收。USDC / EURC / USDbC（Circle）、USDT（tether.to）、WETH（ethereum.org、Base 文档）、DAI / USDS（Sky）、WBTC（wbtc.network）、cbBTC / cbETH（Coinbase）、stETH / wstETH（Lido）、LINK（Chainlink）、UNI（Uniswap）。decimals 有官方文档的照抄，没有的读合约自己的 `decimals()`（公共 RPC、固定区块，来源字段里注明）；文档写明的也逐个和链上值核对过，全部一致。跨链桥版本名字里标 `(bridged)`，测试网标 `(testnet)` |

**没收的**：Sepolia WETH（只有 Uniswap 文档列出，ethereum.org 没有）、Lido 在 Sepolia 上的部署（官方标为已废弃）、各发行方没在官方文档里列出的跨链 / 测试网版本（Base 上的 USDT / DAI / stETH，Sepolia 上的 USDT / DAI / USDS / cbBTC / cbETH / WBTC / UNI）、NFT（没有能核实的）。

## Bybit 重放（2025-02-21）

`testvectors/rules/bybit-2025-02-21.json`，只用公开事后分析里的交易结构，不还原链上原始字节。出处：NCC Group、Verichains、Dfns 的技术分析，Sygnia 的调查，Safe 生态基金会声明，以及 Safe 交易服务里该交易的记录（nonce 和 safeTxHash 只有这里有）。

- 交易：Safe `0x1Db9…FCF4` 以 **DELEGATECALL** 调 `0x9622…7242`，调用数据是 `transfer(0xbDd0…9516, 0)`；那个合约的 `transfer` 把参数写进 slot 0，于是 Safe 的实现合约被换成攻击者的合约。
- 结果：即使这个 Safe 登记在"我的 Safe"里、地址簿为空，也**直接拒签**（`delegateCallNotAllowed`），没有越过的入口；拒签原因先讲 DELEGATECALL。没登记时同样硬拒。
- 当时的签名人签的是**裸哈希**（ETH_SIGN）。同样的请求到 Signer 会被硬拒（`bareHashSigningRejected`）。
- Bybit 的 Safe 是 1.1.1，它的 EIP-712 domain 没有 chainId，所以我们（只支持 ≥ 1.3.0）算出的 safeTxHash 和链上的不同；这个重放测的是规则判断，不是哈希。
