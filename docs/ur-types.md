# 二维码协议：UR、EIP-4527 与自定义类型

> 实现在 `core/Sources/UniPassCore/UR/`，测试在 `core/Tests/UniPassCoreTests/{CBOR,UR,URHardening,URTypes}Tests.swift`。

Signer 和 Coordinator 之间、Coordinator 和外部气隙钱包之间的二维码都用 Blockchain Commons 的 UR 标准：CBOR → bytewords → `ur:` 字符串，长消息用多帧喷泉码。标准类型用 EIP-4527 的 `eth-sign-request` / `eth-signature`，标准不覆盖的三件事用自定义类型：配对、Signer 签名回传、Safe 登记。

规范来源（都按原文核对过）：RFC 8949、BCR-2020-005（UR）、BCR-2020-012（bytewords）、BCR-2024-001（多帧 UR）、BCR-2020-006（类型登记）、EIP-4527、draft-mcnally-deterministic-cbor（dCBOR）。参考实现：URKit、bc-ur（C++）、Keystone `bc-ur-registry-eth` / `keystone-sdk-rust`、Keystone 3 固件、Keycard Shell、AirGap Vault。

## 1. CBOR

**编码**永远是确定性的（RFC 8949 §4.2.1）：整数、长度、tag 用最短形式；只用定长；映射的键按"键的编码字节"字典序排列。

**解码默认从严**（`CBORDecodingOptions.strict`），拒绝：

| 情况 | 错误 |
|---|---|
| 不定长（附加信息 31）、break | `indefiniteLength` |
| 整数 / 长度 / tag 不是最短形式 | `nonShortestEncoding` |
| 映射键没按字节序排列 | `unsortedMapKeys` |
| 映射键重复（**任何模式下都拒绝**） | `duplicateMapKey` |
| 浮点数（UR 和 EIP-4527 里都用不到） | `floatNotSupported` |
| `undefined` 和 false/true/null 以外的 simple 值 | `unsupportedSimpleValue` |
| 文本不是合法 UTF-8 / 不是 NFC（dCBOR 要求） | `invalidUTF8` / `textNotNFC` |
| 附加信息 28–30 | `reservedAdditionalInfo` |
| 解完后还有多余字节 | `trailingBytes` |
| 输入超过 64 KB、嵌套超过 32 层、数据项超过 16384 个 | `inputTooLarge` / `depthExceeded` / `tooManyElements` |

声明的数组 / 映射 / 字节串长度大于剩余输入时，先报错再分配内存，伪造的长度字段不会导致大分配。

**为了互通放宽了什么：CBOR 层没有放宽。** 查过的所有发送方（Keystone JS / Rust、AirGap、MetaMask 的 Keystone keyring、Keycard Shell）发出的都是排好序、最短形式、定长的 CBOR，Keystone 的全部测试向量都是合法 dCBOR。`requireShortestEncoding` / `requireSortedMapKeys` / `requireNFCText` 这几个开关保留着，将来如果遇到不合规但必须兼容的钱包，只在那个调用点放宽，并在这里记录。

## 2. UR 字符串、bytewords、多帧

- 格式：`ur:<type>/<bytewords>`（单帧），`ur:<type>/<seqNum>-<seqLen>/<bytewords>`（多帧）。编码输出小写；放进二维码时整串转大写（`qrString`），只用 QR 字母数字字符集。解码不分大小写。
- 类型名：`[a-z0-9-]+`。顶层 CBOR **不带 tag**（类型名已经说明了类型）；嵌入别的结构时才带 tag。
- bytewords 一律 minimal 风格（每个字节取单词首尾两个字母），数据后跟 4 字节大端 CRC-32/ISO-HDLC。
- 多帧：每帧是 CBOR `[seqNum, seqLen, messageLen, checksum, data]`。分片、Xoshiro256** 随机数、度数采样、分片选择、混合帧异或，全部按参考实现逐字节对齐（官方 20 帧向量逐字一致）。消息只有一片时只产生单帧形式。

**比参考实现更严的地方**（都不影响和真实钱包互通）：

| 情况 | 参考实现 | 我们 |
|---|---|---|
| 空路径段 `ur:bytes//…` | 忽略空段 | 拒绝 |
| seq 段的数字 | `scanInt` / `stoul`，较宽松 | 只认不带前导零、不带符号的十进制，seqNum ≤ 2³²−1 |
| 帧 CBOR 里的整数越界 | URKit 直接崩溃 | 拒绝（`invalidPart`） |
| 帧头自洽 | 不检查 | 要求 `seqLen == ceil(messageLen / 分片长度)`，否则丢弃 |
| 消息大小、分片数、帧数、暂存的混合帧 | 无上限 | 默认 64 KB、256 片、2000 帧、混合帧 4 × seqLen（`FountainDecoder.Limits`）；超限即失败。限制分片数是因为混合帧的分片选择是 O(seqLen²)；限制混合帧是因为恶意发送方可以构造大量互不相同的分片组合，让内存和每帧的归约开销无限增长。我们最大的消息（带 SafeTx JSON 的签名请求）只有几 KB |
| 已开始多帧时混进单帧 | URKit 当成新结果 | 拒绝（`unexpectedPartCount`） |
| `nextDouble()` 恰好等于 1.0（概率约 2⁻⁵⁴） | 下标越界崩溃 | 夹到 1 以下，向量不受影响 |
| 消息短于最小分片长度（10） | 崩溃 | 整条作为一片 |
| 解码顺序 | 字典遍历顺序不定，需要的帧数不确定 | 有序容器，结果和所需帧数都确定 |

和参考实现一致的地方：头部（seqLen、messageLen、checksum、分片长度）和第一帧不一致的帧**丢弃**而不是报错（扫码时屏幕上可能残留别的码）；拼完后 CRC 不对是**致命错误**；格式坏的单帧（bytewords 校验和错、CBOR 不合法）抛错但不影响已累积的状态，可以继续扫。

分片长度沿用参考实现的 `findNominalFragmentLength`，最小分片长度 10。注意它在最小长度起作用时可能返回大于 `maxFragmentLen` 的值，例如 (48, 10, 10) → 12。选择帧大小时留出余量。

**类型由调用方检查。** 解码器只保证 UR 本身合法：一个被改坏的帧可能恰好变成另一个合法类型的单帧 UR（模糊测试里遇到过 `ur:bytesx16-9/…`）。每个具体类型的 `init(ur:)` 都会核对类型名。

## 3. EIP-4527

EIP-4527 文本里没有任何 CBOR / UR 示例，tag 401/402 也只出现在 Keystone 的实现里；CDDL 有两处笔误（`#3.401(sign-data-type)` 实际是裸整数，`#5.304` 实际是 `#6.304`），所有实现都按实际写法处理。我们按实现走。

### `eth-sign-request`（嵌入时 tag 401）

| 键 | 字段 | 类型 | 我们发出 | 我们接受 |
|---|---|---|---|---|
| 1 | request-id | `#6.37(bytes .size 16)` | 总是带（AirGap 没有它会崩） | 可选；有就必须带 tag 37、16 字节 |
| 2 | sign-data | bytes | 必有 | 必有，非空 |
| 3 | data-type | uint：1 交易 RLP、2 EIP-712 JSON、3 personal_sign 原文、4 EIP-2718 | 必有 | 只认 1–4 |
| 4 | chain-id | uint | 有就带 | 可选（MetaMask 签 typed data 时不带） |
| 5 | derivation-path | `#6.304(crypto-keypath)` | 必有，tag 304 | 必有；tag 304 或 40304（BCR v2） |
| 6 | address | bytes .size 20 | 可选 | 可选，20 字节 |
| 7 | origin | text | 可选 | 可选，≤ 256 字节 |

### `crypto-keypath`（tag 304）

`{1: [index, hardened, …], 2: source-fingerprint, 3: depth}`。下标 < 2³¹；通配符 `[]` 能解析；范围形式 `[low, high]` 拒绝（用不到）。最多 16 段（Keycard 是 10 段）。source-fingerprint 不能是 0；components 为空时必须有 source-fingerprint。

### 和外部钱包打交道（Coordinator 侧）

各家钱包对 derivation-path 的处理（读源码得出，未在真机上测）：

| 钱包 | 缺指纹 | 指纹不符 | 空路径 | 其它 |
|---|---|---|---|---|
| Keystone 3 | 报"二维码无效" | 报指纹不匹配 | 签名时报错 | 指纹 = 主密钥指纹；不看 address 字段 |
| AirGap Vault | 崩溃 | 找不到钱包 | — | 指纹 = **账户 xpub 自己的**指纹（偏离 BCR）；没有 request-id 会崩 |
| Keycard Shell | — | 拒绝 | — | 键必须按 1..7 顺序、不能有多余键、tag 必须是 304、最多 10 段 |
| OneKey（GPL，只看行为） | 拒绝 | 拒绝 | 拒绝 | 拒绝通配符 |
| BitTool | 无公开源码，未确定 | | | |

所以 Coordinator 给外部钱包发请求时：derivation-path 用签名地址的**完整** BIP32 路径（不用通配符），指纹**原样回填**设备导出账户时给的那个值（MetaMask 也是这么做的，同时满足 Keystone 和 AirGap）；总是带 request-id；键升序、不加多余的键。

### 发给我们自己 Signer 的请求

Signer 也收标准的 `eth-sign-request`（data-type 2，SafeTx 的 EIP-712 JSON），这样同一个请求码能同时给 Signer 和外部钱包看。Signer 的密钥不是 BIP32 派生的，derivation-path 用规范允许的唯一形式 `{1: [], 2: 指纹}`：

- 指纹 = `SHA-256(0x04 ‖ x ‖ y)` 的前 4 字节（大端），算出 0 时用 1（`SignerPairing.keyFingerprint`）。
- 第三方钱包拿到这个请求会在指纹核对时拒绝，这是想要的结果。
- address（键 6）填这台 Signer 的 proxy 地址，Signer 核对它是不是自己。

### SafeTx 的 EIP-712 JSON（`eth-sign-request` 键 2）

Signer 只接受**一种**序列化（`SafeTxRequest.canonicalJSON`），先逐项校验结构，再要求重新序列化后逐字节相同。这样空白、键顺序、数字写法、重复键、大小写之类的歧义全部排除；外部钱包读这个 JSON 也没有问题（它就是普通的 `eth_signTypedData_v4` 结构）。

```
{"types":{"EIP712Domain":[{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"SafeTx":[{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"data","type":"bytes"},{"name":"operation","type":"uint8"},{"name":"safeTxGas","type":"uint256"},{"name":"baseGas","type":"uint256"},{"name":"gasPrice","type":"uint256"},{"name":"gasToken","type":"address"},{"name":"refundReceiver","type":"address"},{"name":"nonce","type":"uint256"}]},"primaryType":"SafeTx","domain":{"chainId":11155111,"verifyingContract":"0x…"},"message":{"to":"0x…","value":"0","data":"0x","operation":0,"safeTxGas":"0","baseGas":"0","gasPrice":"0","gasToken":"0x0000000000000000000000000000000000000000","refundReceiver":"0x0000000000000000000000000000000000000000","nonce":"7"}}
```

- 紧凑，无空白；键顺序就是上面的顺序；只用可打印 ASCII，不用转义。
- `types` 只能有 `EIP712Domain` 和 `SafeTx`，字段名、类型、顺序逐字一致（Safe ≥ 1.3.0 的类型串，三个版本的合约源码里 typehash 相同）。
- `domain` 只能有 `chainId`（JSON 整数，> 0）和 `verifyingContract`；没有 `name` / `version`（Safe ≥ 1.3.0 的 domain 就是这两项）。
- `message`：uint256 字段用十进制字符串、无前导零；`operation` 用 JSON 整数 0 或 1；地址用 EIP-55；`data` 用小写十六进制，空数据是 `"0x"`。
- safeTxHash 由 Signer 重算。如果调用方另外带了哈希（`expectedHash`），不一致就硬拒。
- 外层 `eth-sign-request`：data-type 必须是 2，必须带 request-id，带了 chain-id 就必须和 domain 的一致。derivation-path 和 address 是否指向这台 Signer 由 Signer 自己核对。

viem 生成的 8 个样例（`testvectors/decoding.json` 的 `typedData`）逐字节等于我们的规范序列化，哈希一致。

## 4. 自定义类型

四个类型的类型名、键号、tag 都定死。**只增不改**：要改语义或删字段就换一个新的类型名。解码一律从严：

- 不认识的键拒绝（和 Keycard 一样严；Signer 和 Coordinator 同步发版，不需要向前兼容）。
- 字段类型、长度、取值范围不对拒绝。
- 可选字段取"空值"（零地址、空字节串、0）时**必须省略**，写出来就拒绝，保证每个值只有一种编码。

嵌入 tag 取 IANA 先到先得区间里 2026-10 时未被占用的 41400–41403（核对过 IANA 登记表，2026-10-08 版：40920–41727 整段 Unassigned）。**尚未向 IANA 登记**，正式发布前要登记。

### `unipass-pairing`（Signer → Coordinator，tag 41400）

| 键 | 字段 | 类型 | 必需 | 约束 |
|---|---|---|---|---|
| 1 | x | bytes | 是 | 32 字节，P-256 公钥 x，大端 |
| 2 | y | bytes | 是 | 32 字节 |
| 3 | name | text | 是 | 1–64 字节 UTF-8，NFC |
| 4 | biometry-policy | uint | 否 | 1 = `.biometryAny`，2 = `.biometryCurrentSet`；调试用软件密钥不带。**只是提示**，Coordinator 不据此放行或拒绝任何操作 |
| 5 | signer-proxy | bytes | 是 | 20 字节，`SafeWebAuthnSignerFactory.getSigner(x, y, verifiers)`，即 Safe 里的 owner 地址 |
| 6 | verifiers | bytes | 是 | 22 字节，P256.Verifiers（uint176：2 字节预编译地址 ‖ 20 字节回退验证合约） |
| 7 | signer-factory | bytes | 是 | 20 字节，`SafeWebAuthnSignerFactory` 地址 |

Coordinator 应当用 factory 的 `getSigner(x, y, verifiers)` 核对 signer-proxy。

例（`UniPassURTypesTests.pairingGolden`）：`{1: h'11…11', 2: h'22…22', 3: "iPhone", 4: 1, 5: h'c8f9…9a06', 6: h'0100445a…e765', 7: h'1d31…1195'}` 编码为 `a7 01 5820 11…11 02 5820 22…22 03 66 6950686f6e65 04 01 05 54 c8f9… 06 56 0100… 07 54 1d31…`。

### `unipass-signature`（Signer → Coordinator，tag 41401）

一次 WebAuthn 断言签名，格式见 `docs/webauthn-signature.md`。

| 键 | 字段 | 类型 | 必需 | 约束 |
|---|---|---|---|---|
| 1 | request-id | `#6.37(bytes .size 16)` | 是 | 回显请求的 request-id |
| 2 | authenticator-data | bytes | 是 | 37–1024 字节 |
| 3 | client-data-fields | text | 是 | ≤ 1024 字节 |
| 4 | r | bytes | 是 | 32 字节，0 < r < n |
| 5 | s | bytes | 是 | 32 字节，0 < s ≤ n/2（**low-s**；合约不拒绝 high-s，这是唯一的防线） |

不带 challenge（safeTxHash）：Coordinator 用自己发出的请求重算，不信任回传值。`SignerSignature.proxySignature` 给出交给 `SafeWebAuthnSignerProxy` 的 ABI 编码签名。

例（`signatureGoldenFromDevice`，用的是 iPhone 15 Pro 真机签名）：`a5 01 d825 50 <16 字节> 02 5825 bd28ca87…862e 05 00000000 03 783e "origin":… 04 5820 <r> 05 5820 <s>`。

### `unipass-safe`（Coordinator → Signer，tag 41402）

登记一个"我的 Safe"。带上创建时的全部参数，Signer 离线用 CREATE2 重算 Safe 地址核对，不信任 Coordinator 给的地址。

| 键 | 字段 | 类型 | 必需 | 约束 |
|---|---|---|---|---|
| 1 | chain-id | uint | 是 | > 0 |
| 2 | safe | bytes | 是 | 20 字节 |
| 3 | proxy-factory | bytes | 是 | 20 字节，SafeProxyFactory |
| 4 | singleton | bytes | 是 | 20 字节，Safe / SafeL2 |
| 5 | salt-nonce | bytes | 是 | 32 字节，uint256 大端 |
| 6 | owners | `[bytes]` | 是 | 1–50 个 20 字节地址，不能是零地址或哨兵 `0x…01`，不能重复；顺序就是 `setup` 里的顺序 |
| 7 | threshold | uint | 是 | 1 ≤ threshold ≤ owner 数 |
| 8 | to | bytes | 否 | 20 字节；零地址时省略 |
| 9 | data | bytes | 否 | 1–16384 字节；为空时省略 |
| 10 | fallback-handler | bytes | 是 | 20 字节（可以是零地址） |
| 11 | payment-token | bytes | 否 | 20 字节；零地址时省略 |
| 12 | payment | bytes | 否 | 32 字节 uint256；为 0 时省略 |
| 13 | payment-receiver | bytes | 否 | 20 字节；零地址时省略 |
| 14 | name | text | 否 | 1–64 字节，只用于显示 |

键 6–13 就是 `Safe.setup(owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver)` 的参数。

Signer 登记前做三项核对（`SafeAddress.verify(_:signer:)`，结果是 `VerifiedSafe`，Signer 的本地存储只收这个类型）：

1. CREATE2：链在首发范围、factory 和 singleton 是官方部署、按参数算出的地址和键 2 一致；
2. **setup 没有改动 Safe 的余地**：CREATE2 只证明创建参数，证明不了 setup 执行后的状态，所以
   - 键 8、9（to、data）必须都没有：setup 会 DELEGATECALL `to`，能在创建时加 module 或 owner（`setupCall`）；
   - 键 11–13（付款）必须都没有（`setupPayment`）；
   - 键 10（fallback handler）只能是零地址或 singleton **同版本**官方的 CompatibilityFallbackHandler（`SafeAddress.compatibilityFallbackHandlers`；1.3.0 收 canonical 和 eip155 两个，ExtensibleFallbackHandler 不收）。fallback handler 会回答 EIP-1271 签名校验，换成别的合约就能让 Safe 认可任何签名（`unofficialFallbackHandler`）。登记页的"技术细节"里显示它；
3. **本机在 owner 里**：本机的 signer proxy 地址在键 6 里，不在就拒绝登记（`signerNotAnOwner`）。

CREATE2 只能证明 Safe **创建时**的 owner 和门限，之后链上改过的话 Signer 不知道，登记页上写明。

### `unipass-sign-request`（Coordinator → Signer，tag 41403）

一次扫码同时带上签名请求和这个 Safe 的登记信息，让"登记 Safe"并入第一次签名。标准 `eth-sign-request` 原样嵌入，本身不改、不加字段。

| 键 | 字段 | 类型 | 必需 | 约束 |
|---|---|---|---|---|
| 1 | request | `#6.401(eth-sign-request)` | 是 | 必须带 tag 401；内容按第 3 节 `eth-sign-request` 的规则解码 |
| 2 | safe | `#6.41402(unipass-safe)` | 是 | 必须带 tag 41402；内容按上面 `unipass-safe` 的规则解码 |

没有可选键，多余的键、缺 tag 或 tag 不对都拒绝。编码以 `a2 01 d9 0191 …` 开头。

Signer 收到后：

| 情况 | 处理 |
|---|---|
| 这个 Safe（链 + 地址）已经登记 | 忽略登记部分，按普通签名请求评估 |
| 请求解不出 SafeTx，或请求签的不是键 2 里的这个 Safe | 忽略登记部分，按普通签名请求评估（没登记的 Safe 照样被硬拒） |
| 没登记，且请求签的正是这个 Safe | 按上面两项核对；通过后显示"首次见到这个 Safe"（owner、门限、本机在哪），用户确认后登记，再进入这笔交易的确认页；核对不通过就报错，不登记 |

单独的 `unipass-safe` 登记流程保留。Coordinator 不知道 Signer 有没有登记过时，可以一律发这个类型。

## 5. 测试向量

| 文件 | 内容 | 来源与许可证 |
|---|---|---|
| `testvectors/ur/bc-ur.json` | CRC32、Xoshiro256、采样器、洗牌、分片、度数、分片选择、20 帧多帧 UR、bytewords、BCR 示例 | URKit / bc-ur 测试文件、BCR-2020-005/012（BSD-2-Clause-Patent），bc-ur-rust（BSD-2-Clause-Patent），ur-rs（MIT）。用脚本从源文件原样提取，未手抄 |
| `testvectors/ur/eip4527-keystone.json` | 3 个 `eth-sign-request`、2 个 `crypto-keypath`、1 个批量请求（文件里还有 1 个 `eth-signature`，core 不实现这个类型，不解析它） | `keystone-airgaped-base` `packages/ur-registry-eth`（ISC，在 package.json 声明），`keystone-sdk-rust` `libs/ur-registry`（MIT） |
| 测试代码内 | RFC 8949 附录 A（IETF Trust），自定义类型的手写期望编码 | — |

另有固定种子的模糊测试：CBOR 解码 20000 个随机 / 变异输入（严格解码成功时重新编码必须逐字节相同），UR 解码器 300 轮 × 30 帧变异输入。

## 6. 待定 / 未验证

- tag 41400–41403 还没向 IANA 登记。
- BitTool 没有公开源码，容忍度未知；各钱包的行为来自读源码，没有真机测过。
- 如果外部钱包用 personal_sign（data-type 3）签 safeTxHash，提交给 Safe 前 v 要加 4（eth_sign 类型签名）。这一条还没有对照 Safe 合约源码核实。
