# Signer 的 WebAuthn 签名格式

> 状态：**M0 已验证**（2026-10-25）。依据：safe-modules `passkey/v0.2.1` 源码 + `contracts/` 的测试（本地源码构建 + Sepolia fork 上的 Safe 1.3.0 / 1.4.1 / 1.5.0 正式部署）。复现方法见文末。

Signer 的 Secure Enclave P-256 密钥不是真正的 WebAuthn authenticator：它不走系统的 passkey 流程，而是由 Signer 自己拼出 WebAuthn 断言的各个字段，再用 SE 对它们签名。链上的 owner 是 safe-modules 的 `SafeWebAuthnSignerProxy`（由 `SafeWebAuthnSignerFactory` 用 CREATE2 部署），它把调用转给 `SafeWebAuthnSignerSingleton`，按 WebAuthn 的规则验签。

## 签什么

### challenge

`challenge` = Safe 交给 signer 校验的 32 字节值，**就是 safeTxHash**（EIP-712 哈希，和 EOA owner 签的是同一个值）。三个 Safe 版本走的路径不同，结果相同：

| Safe | Safe 调 owner 的接口 | 传入的数据 | proxy 实际用作 challenge 的值 |
|---|---|---|---|
| 1.3.0、1.4.1 | 旧版 `isValidSignature(bytes data, bytes sig)`，要求返回 `0x20c13b0b` | `data` = EIP-712 原像 `0x19 ‖ 0x01 ‖ domainSeparator ‖ safeTxStructHash`（Safe 先校验 `keccak256(data) == dataHash`，否则 GS027） | `keccak256(data)` = safeTxHash |
| 1.5.0 | ERC-1271 `isValidSignature(bytes32 hash, bytes sig)`，要求返回 `0x1626ba7e` | `hash` = safeTxHash | safeTxHash |

proxy 两种接口都实现（`SignatureValidator`），所以同一个 signer、同一份签名在三个版本上都能用。测试：`test_challengeIsSafeTxHash`、`test_execTransaction_eoaAndPasskey`（各版本）。

消息签名（EIP-1271，v1.1 范围）时 challenge 应为 SafeMessage hash（`CompatibilityFallbackHandler.getMessageHashForSafe`），走同样的路径；**本次未测**。

### authenticatorData（37 字节）

`rpIdHash(32) ‖ flags(1) ‖ signCount(4, 大端)`

- `rpIdHash` = `sha256("unipass.xyz")` = `0xbd28ca874e746c460d047bbcd8110dc4eda0ae9f5ca3f002ba659170645f862e`（core 里是 `WebAuthnAssertion.signerRPID`）。**合约不校验**，任意值都行。
- `flags` = `0x05`（UP | UV）。合约**只要求 UV（0x04）置位**：`authenticatorData[32] & 0x04 == 0x04`。UP、BE、BS、AT、ED 等位都不检查。所以 `0x04` 也能过，`0x01` 必失败。我们固定用 `0x05`。
- `signCount` = `0x00000000`。合约不校验。
- 合约不检查 authenticatorData 的长度（只读第 33 个字节），但签名覆盖整个 authenticatorData，签完不能改任何字节。

### clientDataFields 和 clientDataJSON

- `clientDataFields` = `"origin":"unipass-signer://secure-enclave","crossOrigin":false`（UTF-8，无首尾逗号或花括号）。定为此值；合约不解析它，任何字节串都行，只要和签名时一致。越短越省 calldata。
- 合约重建（`WebAuthn.encodeClientDataJson`）：

  ```
  {"type":"webauthn.get","challenge":"<base64url(challenge)>",<clientDataFields>}
  ```

  - base64url 用 `-_` 字母表、**无填充**，32 字节固定得到 43 个字符（最后一个字符只编码 4 位，后面补两个 0 位）。
  - 前缀、`",` 和结尾的 `}` 都由合约写死，中间没有空格。长度 = 82 + len(clientDataFields)。
- 已用 safe-modules 的 `WebAuthn` 库对我们的独立实现做模糊对拍（`testFuzz_clientDataJsonMatchesLibrary`、`testFuzz_signingMessageMatchesLibrary`），并用 Node crypto 再核对了一遍测试向量。

### 签名消息

- 签名消息 `message` = `authenticatorData ‖ sha256(clientDataJSON)`（37 + 32 = 69 字节）
- ECDSA 的摘要 `digest` = `sha256(message)`，P-256 验签（0x100 预编译或 fallback verifier）收到的就是它。
- Signer 用 CryptoKit 时：对 `message` 调 `SecureEnclave.P256.Signing.PrivateKey.signature(for: message)`（它内部做一次 SHA-256），或对 `digest` 调 `signature(for: SHA256Digest)`，两者等价。**不要**把 `digest` 当普通数据再签一次。

## 输出

### r、s 与 low-s

- `r`、`s` 各 32 字节（CryptoKit 的 `rawRepresentation` 就是 `r ‖ s`）。
- **合约不拒绝高 s。** singleton 调的是 `P256.verifySignatureAllowMalleability`；0x100 预编译（EIP-7951）、FCL verifier、Daimo verifier 也都接受 `s > n/2`（`test_highSAcceptedByContract`、`test_verifiersAcceptBothS`，向量 `high-s-accepted.json`）。
- 我们仍然**必须**做 low-s 规范化（`s > n/2` 时取 `n − s`，n = `0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551`），让同一笔交易的签名唯一。CryptoKit 不保证输出 low-s。Coordinator 收到高 s 应当判为 Signer 实现错误，不应自行改写后上链。
- 可塑性本身对 Safe 无害（safeTxHash 含 nonce，不能重放）。

### 交给 proxy 的签名

`abi.encode(bytes authenticatorData, string clientDataFields, uint256 r, uint256 s)`，标准 ABI 编码：

```
0x00  offset(authenticatorData) = 0x80
0x20  offset(clientDataFields)  = 0x80 + 0x20 + pad32(len(authenticatorData))   // 37 字节时为 0xe0
0x40  r
0x60  s
0x80  len(authenticatorData) ‖ authenticatorData（右补零到 32 字节对齐）
....  len(clientDataFields)  ‖ clientDataFields（右补零到 32 字节对齐）
```

- 合约有长度上限：`len(signature) ≤ 192 + pad32(len(authenticatorData)) + pad32(len(clientDataFields))`，多一个字节都会失败（防止 4337 下用填充抬高验签 gas）。标准 `abi.encode` 正好等于上限。测试：`test_revert_paddedSignature`，向量 `invalid-padded.json`。
- 默认字段下（authenticatorData 37 字节、clientDataFields 62 字节）签名长 320 字节（192 + 64 + 64）。

### 包成 Safe 签名

Coordinator 把它作为合约签名放进 Safe 的 `signatures`（1.3.0 – 1.5.0 相同）：

- 静态部分每个签名 65 字节，**按 owner 地址升序排列**（EOA 和合约 owner 混在一起排；否则 GS026）。
  - EOA：`r(32) ‖ s(32) ‖ v(1)`
  - 合约 owner（proxy）：`bytes32(proxy 地址，左补零) ‖ bytes32(offset) ‖ 0x00`
- 动态部分接在所有静态部分之后：`uint256(len) ‖ proxy 签名`。`offset` 从 `signatures` 开头算起，指向 len 字段。proxy 签名本身已 32 字节对齐，不需要额外填充。
- `offset ≥ threshold × 65`（GS021），`offset + 32 + len ≤ len(signatures)`（GS022 / GS023）。按"先写全部静态部分、再按同样顺序写动态部分"就自然满足。
- 例：2-of-3，EOA 地址 < proxy 地址：`EOA(65) ‖ proxy, offset=130, v=0 (65) ‖ len ‖ sig`。参考实现：`contracts/src/SafeSignatures.sol`。

## proxy 地址和 verifiers

### verifiers 编码

`P256.Verifiers` 是 `uint176`：`uint16(precompile) << 160 | uint160(fallbackVerifier)`。singleton 先调预编译，**失败（含预编译不存在）再调 fallback**。预编译填 0 表示不用预编译，fallback 填 0 表示没有 fallback。

**我们统一用** `0x0100 ‖ FCLP256Verifier`：

```
verifiers = 0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765
```

- 以太坊主网（Fusaka 后 EIP-7951）和 RIP-7212 L2 的 P-256 预编译都在 `0x100`，接口相同（160 字节输入，成功返回 32 字节的 1，失败返回空）。按规范 gas 不同（EIP-7951 6900，RIP-7212 3450），但 Base 实测已按 6900 收费（见"规范部署"）。
- 带上 FCL fallback：在还没有预编译的链上也能用（贵很多，见下），预编译上线后自动变便宜，地址不变。
- proxy 地址取决于 verifiers；所有链用同一个值，同一把 SE 密钥在所有链上得到**同一个 signer 地址**（factory 是确定性部署）。
- 代价：**无效签名**会在预编译失败后再走一遍 FCL，额外约 20 万 gas；只影响注定失败的交易和 gas 估算。

### 地址计算（离线可算）

```
signer = CREATE2(factory, salt = 0, keccak256(proxyCreationCode ‖ uint256(singleton) ‖ x ‖ y ‖ uint256(verifiers)))
```

`proxyCreationCode`（437 字节）是从 Sepolia 上 factory 的 runtime code 里取出的（第 1653–2090 字节），记录在 `contracts/src/PasskeyDeployments.sol`；fork 测试断言用它离线算出的地址等于 `factory.getSigner(...)`（`test_offlineSignerAddress`）。core 需要离线算地址时用这段字节码。注意：自己从源码编译出的 proxy 字节码因 metadata 不同，算出的地址不一样。

### 规范部署（2026-10-26 核对：以太坊主网 1、Base 8453、Sepolia 11155111）

用公共 RPC（publicnode）只读核对：对每个地址取 `eth_getCode`，比较 runtime code 的 keccak256。下表所有合约在三条链上**都已部署，且 runtime code 完全一致**，所以首发链（主网 + Base）**不需要补部署任何合约**。

| 合约 | 地址 | codehash（前 6 字节）/ 字节数 |
|---|---|---|
| SafeWebAuthnSignerFactory（passkey v0.2.1） | `0x1d31F259eE307358a26dFb23EB365939E8641195` | `0x655b1f71eedf` / 2143 |
| SafeWebAuthnSignerSingleton（`factory.SINGLETON()`，三链返回值相同） | `0x4E27b51350e6c2083EE19011120F50DAfEc5CA50` | `0x2f10c1deb6dc` / 2246 |
| FCLP256Verifier | `0x445a0683e494ea0c5AF3E83c5159fBE47Cf9e765` | `0x0d23c6a31df5` / 5770 |
| DaimoP256Verifier（备用，更贵） | `0xc2b78104907F722DABAc4C69f826a522B2754De4` | `0x3cd725b6ba67` / 3537 |
| SafeWebAuthnSharedSigner（4337 用，我们不用） | `0x94a4F6affBd8975951142c3999aEAB7ecee555c2` | `0xeaa32d028005` / 2954 |
| Safe 1.4.1 / SafeL2 1.4.1 | `0x41675C099F32341bf84BFc5382aF534df5C7461a` / `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | `0x1fe2df852ba3` / `0xb1f926978a0f` |
| SafeProxyFactory 1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | `0x50c3cdc40747` / 3054 |
| MultiSend / MultiSendCallOnly 1.4.1 | `0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526` / `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` | `0x0e4f7fc66550` / `0xecd5bd14a08c` |
| CompatibilityFallbackHandler 1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | `0x7c6007a5d711` / 5637 |
| Safe 1.3.0（canonical 与 eip155 两套地址都在）、Safe 1.5.0：singleton、L2 singleton、proxy factory、MultiSend、MultiSendCallOnly、CompatibilityFallbackHandler | 见 `contracts/src/SafeDeployments.sol` 和 safe-deployments | 三链一致 |
| 确定性部署器：Arachnid `0x4e59b448…956c`、Safe Singleton Factory `0x914d7Fec…43d7` | | 三链一致 |

- **0x100 P256VERIFY 在三条链上都可用**：用 `valid-basic.json` 的 `signingDigest ‖ r ‖ s ‖ x ‖ y` 直接 `eth_call 0x100`，返回 `…01`；把 y 换成 x 后返回空。
- **gas**：按 `eth_estimateGas` 反推（直接调 0x100 时为 30,751，同样 calldata 调空地址为 27,595），主网和 **Base** 上这个预编译都约 **6900 gas**，即 EIP-7951 的定价，不是 RIP-7212 的 3450。所以下面 gas 表里"有预编译"的数字对 Base 同样适用。
- **设备 signer 地址三链相同**：新设备公钥（`device/signer-key.json`）配默认 verifiers，三条链的 `factory.getSigner` 都返回 `0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06`，与离线计算一致；三条链的 `isValidSignatureForSigner` 都接受设备签名（`signer-safetx.json`）。这个 proxy 目前只在 Sepolia 上部署了，主网和 Base 上要在建 Safe 的同一笔交易里部署（`DeployTestSafe` 的做法，见下节）。`createSigner` 无需权限，由发起建 Safe 交易的用户钱包出 gas。
- 万一以后要上一条缺少这些合约的链：passkey 合约和 Safe 合约都经 **Safe Singleton Factory**（`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`）确定性部署（safe-modules 的 `hardhat.config.ts` 里 `deterministicDeployment` 取自 `@safe-global/safe-singleton-factory`）。在新链上用同样的 init code（同版本、同编译设置）和 salt 重放，就能得到同样的地址。gas 由部署者自己出，任何人都可以做。前提是这条链上已经有 Safe Singleton Factory，没有的话要先向 safe-global/safe-singleton-factory 申请。主网和 Base 现在都不需要这样做。

## 建 Safe：owner 可以是还没部署的 proxy

- `Safe.setup` 不检查 owner 有没有代码，**可以直接用 `getSigner` 算出的预测地址当 owner**。proxy 部署前，用它签的交易会失败（调用无代码地址时回滚）；任何人调 `factory.createSigner(x, y, verifiers)` 部署后，同一份签名立即有效（`test_ownerCanBeUndeployedSigner`）。`createSigner` 无需权限、可重复调用（已部署则直接返回地址）。
- 一笔交易同时部署，三种方式都验证通过（三个 Safe 版本）：
  1. EOA 直接调 `MultiSendCallOnly.multiSend([factory.createSigner, proxyFactory.createProxyWithNonce])`（`MultiSendCallOnly` 允许直接调用；`MultiSend` 不行）。
  2. 顺序反过来（先建 Safe 再部署 signer）也可以。
  3. 只调一次 `proxyFactory.createProxyWithNonce`：`setup` 的 `to = MultiSendCallOnly`、`data = multiSend([factory.createSigner])`，Safe 初始化时 delegatecall 它去部署 signer。Safe 地址会因 `setup` 参数不同而不同。
- 建议 Coordinator 用方式 1（意图最直白，Safe 地址只取决于 owners/threshold）。

## 各 Safe 版本差异

| | 1.3.0 | 1.4.1 | 1.5.0 |
|---|---|---|---|
| 调 owner 的接口 | `isValidSignature(bytes,bytes)` → `0x20c13b0b` | 同 1.3.0 | `isValidSignature(bytes32,bytes)` → `0x1626ba7e` |
| challenge | keccak256(EIP-712 原像) = safeTxHash | 同左 | safeTxHash |
| 签名布局、排序、错误码 | GS020–GS026 | 同 1.3.0 | 相同错误码（改用自定义 revert 实现，字符串仍为 `GSxxx`） |
| WebAuthn signer 能否当 owner | 能 | 能 | 能 |

签名格式在三个版本上**完全相同**，Signer 不需要知道 Safe 版本。

## Gas（Sepolia fork，Osaka EVM，即当前主网规则）

2-of-2 Safe，ETH 转账，nonce 1→2（不含首笔交易 nonce 0→1 多出的约 1.7 万）。`exec` 是 `execTransaction` 的执行 gas；`tx` = 21000 + max(calldata 4/16 计价 + exec，EIP-7623 floor)。FCL / Daimo 的数字和具体签名值有关，有几千 gas 的波动。

| 签名者 | Safe 1.3.0 tx | Safe 1.4.1 exec / tx | Safe 1.5.0 tx |
|---|---|---|---|
| EOA + EOA（基线，calldata 548 B） | 90,336 | 65,542 / 90,438 | 89,934 |
| EOA + passkey，verifiers = 0x100 + FCL，有预编译（calldata 900 B） | 112,332 | 84,752 / **112,520** | 111,072 |
| 同上，在仍按 RIP-7212 收费（3450）的 L2 上（Base 不是，按 6900 收费） | ≈108,900 | ≈109,100 | ≈107,600 |
| 同上，链上无预编译 → 走 FCL | 316,135 | 294,463 / 322,207 | 316,640 |
| verifiers = 仅 FCL | 318,479 | 296,332 / 324,100 | 317,166 |
| verifiers = 仅 Daimo | 450,636 | 420,389 / 448,157 | 453,755 |

- 有预编译时，passkey owner 比 EOA owner 多约 **2.2 万 gas**（执行约 1.9 万，多出的 352 字节 calldata 约 3k）。
- 单独调 proxy 的 `isValidSignature`：预编译 32,793；FCL ≈ 239,700；Daimo ≈ 365,000。
- 部署 proxy（`createSigner`）：执行 109,519，整笔交易约 13.2 万（+21000 +calldata 约 1.4k）。

**Sepolia 当前规则（2026-10-06 起比 Osaka 新的分叉，`--evm-version amsterdam`）**：执行交易只略贵，部署合约贵很多。

- Safe 1.4.1，2-of-2 转账（估算方法同上）：EOA + passkey 117,720（Osaka 下 112,520）；EOA + EOA 94,738；仅 FCL 328,434；仅 Daimo 452,672。单独调 `isValidSignature`，走预编译时 33,593。
- 一笔交易部署 proxy + SafeL2，实测上链 1,947,233 gas（`DeployTestSafe`，交易 `0xa9e27b58…c7cb`）；Osaka 规则下约 40 万。
- 主网升级到这个分叉后，部署成本按 Sepolia 的数字估。做 gas 估算时一定要用节点的 `eth_estimateGas`，或者用与目标链一致的 `--evm-version`。

## 测试向量

`testvectors/webauthn/*.json`，由 `contracts/script/GenerateWebAuthnVectors.s.sol` 生成（`cd contracts && forge script script/GenerateWebAuthnVectors.s.sol`，不需要 RPC）。`expectedValid` 不是手写的：脚本在本地 EVM 里用源码构建的 passkey v0.2.1 singleton + 默认 verifiers 实际验签得出；`forge test` 里的 `test_committedVectors` 每次重新核对。

| 文件 | 内容 | expectedValid |
|---|---|---|
| `valid-basic.json` | Signer 默认参数 | true |
| `valid-challenge-zero.json` | challenge 全 0（43 个 `A`） | true |
| `valid-challenge-ones.json` | challenge 全 1（`_` 和最后 4 位分组） | true |
| `valid-uv-only.json` | flags = 0x04 | true |
| `valid-other-fields.json` | 其他 clientDataFields | true |
| `high-s-accepted.json` | s 换成 n − s：链上接受，但 `lowS = false`，Signer 不得产出 | true |
| `invalid-flags-up-only.json` | flags = 0x01 | false |
| `invalid-wrong-challenge.json` | 签的是另一个 challenge | false |
| `invalid-tampered-fields.json` | 签名后改了 clientDataFields | false |
| `invalid-padded.json` | 签名末尾多 32 个零字节 | false |

字段（hex 均为 `0x` 小写；地址为校验和格式）：

- `privateKey`（仅测试用，由固定字符串派生）、`x`、`y`
- `challenge`（链上传给 signer 的值）、`signedChallenge`（实际签的值；只有 wrong-challenge 向量两者不同）
- `rpId`、`rpIdHash`、`flags`、`signCount`、`authenticatorData`
- `clientDataFields`、`challengeBase64Url`、`clientDataJSON`、`clientDataHash`、`signingMessage`、`signingDigest`：均为**验签方**按 `challenge` 和链上字段重算的值
- `r`、`s`、`lowS`、`signature`（ABI 编码，交给 proxy 的字节）
- `verifiers`、`signerFactory`、`signerSingleton`、`signerAddress`（规范 factory 下的 proxy 地址）
- `safeSignature`：假设这是唯一一个签名时包好的 Safe `signatures`（offset = 65）
- `expectedValid`

## 真实设备

`testvectors/webauthn/device/`，由 apps/signer 在 iPhone 15 Pro Secure Enclave（`.biometryAny`）上产出。

### 当前（rpId `unipass.xyz`，Bundle ID `xyz.unipass.signer`）

- 公钥 `device/signer-key.json`，signer 地址 `0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06`（与规范 factory 的 `getSigner` 一致）。
- 设备对一笔真实 SafeTx 签名（`device/signer-safetx.json`）：Safe 1.4.1，Sepolia，2-of-2 = 测试 EOA + 设备 signer，Safe `0xE8982BeA17b5959D7bDA9571f0c183914B8B06Db`（只存在于 fork），转 1 wei 到 `0xBEEF`，nonce 0，safeTxHash `0xedc1403872e38762c0f7832dde77fc5da03ff4684044761d617a30a1ecf4198d`。Signer 用 core 的 SafeTx 独立算出了同一个 hash。
- 结构：authenticatorData = `sha256("unipass.xyz") ‖ 0x05 ‖ 00000000`，clientDataFields 为默认值，标准 ABI 编码，low-s。这次 SE 原始输出是高 s，由 Signer 规范化成 low-s，即规范化路径也经过了真机验证。
- 在 Sepolia fork 上 `execTransaction` 成功（`test_currentDeviceSafeTx`）；在真实 Sepolia 节点上 `eth_call` 规范 factory 的 `isValidSignatureForSigner`，默认 verifiers 和仅预编译时都返回 `0x1626ba7e`。

### 真实 Sepolia 上链（2026-10-25）

- 部署：`DeployTestSafe` 部署了 SafeL2 1.4.1 `0x8ceb01112162b035BE3D38740f8233d28DA0E4a1`（2-of-2：设备 signer proxy `0xc8F9…9A06` + 测试 EOA），交易 `0xa9e27b58…c7cb`。
- 执行：Coordinator 从 STS 读回测试 EOA 的签名和 proxy 的 CONTRACT_SIGNATURE，用 core 的 `SafeSignatures.encode` 拼成 482 字节的 `signatures`，执行 nonce 0 的交易 `0x1e546e1c6930f6842370ac2c66270db595a7f2ca7e58c71687cd21294806e3d2`（区块 11991396，to `0xBEEF`，value 0，data `0x01`）。链上返回 status 1，并有 `ExecutionSuccess` 事件；gas 用了 191,168（节点估算 193,852）。比上面 fork 估算的转账贵，主要多在 nonce 首次写入、SafeL2 事件和更长的 calldata（932 字节）。
- 这是整条链路第一次在真实链上跑通：设备 SE 签名 → Signer 编码 → STS → core 打包 → Safe 链上验签。

## 复现

```bash
cd contracts
forge test                                   # 本地：源码构建的 Safe 1.4.1 + passkey v0.2.1
SEPOLIA_RPC_URL=<url> forge test -vv         # 另加 Sepolia fork：Safe 1.3.0/1.4.1/1.5.0 正式部署 + gas 输出
```

`SEPOLIA_FORK_BLOCK` 可固定区块（需要归档节点）。依赖以 git submodule 固定：safe-smart-account `v1.4.1`、safe-modules `passkey/v0.2.1`、forge-std `v1.17.0`。

## 仍未确认

- SafeMessage（EIP-1271 消息签名）路径未测，留到 v1.1。

## 许可证

safe-smart-account 和 safe-modules 的合约源码文件均为 `LGPL-3.0-only`（仓库 LICENSE 为 LGPL-3.0；passkey 的 npm 包标 GPL-3.0，按 GPL 对待）。`contracts/` 只把它们作为 submodule 调用，不修改。我们自己的代码为 Apache-2.0；`contracts/src/PasskeyDeployments.sol` 和 `apps/signer/SignerKit/Sources/SignerKit/SignerProxy.swift` 内嵌了 signer proxy 的编译字节码，沿用 LGPL-3.0-only（见 NOTICE）。
