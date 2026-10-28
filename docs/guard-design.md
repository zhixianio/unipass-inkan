# 链上 Safe Guard 设计（第三层防线）

> 状态：**设计草案，未实现**（2026-10-27）。依据：Safe 1.3.0 / 1.4.1 / 1.5.0 源码（`contracts/lib/safe-smart-account` 的对应 tag）、`docs/rules.md`。文中的 gas 和工作量都是估算，标了"估"。

## 0. 摘要

| 防线 | 谁 | 防什么 |
|---|---|---|
| 第一层 | Signer 的规则（`docs/rules.md`，R01 DELEGATECALL、R02 改配置等） | 签名人看清自己在签什么 |
| 第二层 | 多签阈值 | 单个设备或单个人被骗、被控制 |
| **第三层** | **链上 Guard** | **所有签名人都被骗、签名已经凑够时**，链上仍然拒绝最危险的两类操作，并给"没被骗的那一个"留出否决的时间 |

三条规则：

1. **DELEGATECALL 只允许调官方 MultiSendCallOnly**，并且只能调它的 `multiSend(bytes)`。Bybit 那种委托调用到恶意合约的交易，签名凑够了也会被拒。
2. **改配置要先排期，等待期过后才能执行**。改配置指对 Safe 自身的任何带数据的调用，卸掉 Guard 本身也算在内。
3. **等待期内，任意一个 owner 都能否决**。owner 签一条 EIP-712 消息，任何人都可以代为提交；合约 owner 用 EIP-1271 验证。

关键设计决定：

- 排期按**变更内容**记录，而不是按 safeTxHash 记录（第 4.3 节）。
- Guard **不可升级、没有管理员**；等待期在部署时写死，不能改。
- "必须始终放行 `setGuard(0)`"（F4）的落地方式是：卸 Guard 和其它配置一样要排期、等待，但它走一条**最短、不依赖任何解析和外部调用**的路径，保证 Guard 其它部分有 bug 也不影响卸载（第 6 节）。
- 一个 owner 不能否决"单纯移除自己"的变更，防止一个作恶的 owner 用否决权把整个 Safe 锁死（第 5.4 节）。

## 1. Safe 的 Guard 接口（三个版本）

| | 1.3.0 | 1.4.1 | 1.5.0 |
|---|---|---|---|
| 交易 Guard 接口 | `Guard` | `Guard is IERC165` | `ITransactionGuard is IERC165` |
| `checkTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures, msgSender)` | ✅ 选择器 `0x75f0bb52` | ✅ 同左 | ✅ 同左 |
| `checkAfterExecution(bytes32 txHash, bool success)` | ✅ `0x93271368` | ✅ | ✅（参数名 `hash`） |
| `setGuard` 时检查 ERC-165 | ❌ | ✅ `supportsInterface(0xe6d7a83a)`，否则 GS300 | ✅ 同左 |
| 存储槽 | `0x4a204f62…c34c8` | 同左 | 同左 |
| 模块交易（`execTransactionFromModule`）经过 Guard 吗 | **不经过** | **不经过** | 不经过交易 Guard；**另有 Module Guard** |
| Module Guard | — | — | `IModuleGuard`（interfaceId `0x58401ed8`）：`checkModuleTransaction(to, value, data, operation, module) returns (bytes32)` 和 `checkAfterModuleExecution(bytes32, bool)`。用 `setModuleGuard(address)`（`0xe068df37`）设置，同样检查 ERC-165，否则 GS301 |

- 调用顺序（三个版本相同）：`execTransaction` 先算 safeTxHash，nonce 加 1，校验签名，然后调 `checkTransaction`，再执行交易本身，最后调 `checkAfterExecution`。**两个钩子里任何一个 revert，整笔交易就失败**，包括 `setGuard` 本身，因为它也是一笔 `execTransaction`。这就是锁死风险的来源（第 6 节）。
- `setup()` 不经过 Guard。新 Safe 在 `setup` 里设好 Guard，就不会有一段没有 Guard 的窗口（第 8 节）。

一份 Guard 合约同时实现 `Guard`/`ITransactionGuard` 和 `IModuleGuard`，`supportsInterface` 对 `0xe6d7a83a`、`0x58401ed8`、`0x01ffc9a7` 都返回 true，就能同时用于三个版本。

## 2. 术语

- **self**：被保护的 Safe。在 `checkTransaction` 里就是 `msg.sender`。
- **配置调用**：`operation = CALL`、目标是 self、`data` 非空的调用（定义见 3.2）。
- **变更**：一笔需要排期的 Safe 交易，按它的 `(to, value, data, operation)` 识别。
- **变更哈希** `changeHash = keccak256(abi.encode(self, to, value, keccak256(data), operation))`。

## 3. 规则的精确定义

### 3.1 规则 1：DELEGATECALL

`operation == DELEGATECALL` 时，以下三条必须同时满足，否则 revert：

- `to` 在白名单里：MultiSendCallOnly 1.3.0 `0x40A2aCCbd92BCA938b02010E17A5b8929b49130D`、1.3.0 eip155 `0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B`、1.4.1 `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`、1.5.0 `0xA83c336B20401Af773B6219BA5027174338D1836`。四个地址在主网、Base、Sepolia 上代码相同，已核对（`docs/webauthn-signature.md`"规范部署"）。白名单是常量，写死在合约里。
- `data` 恰好是 `multiSend(bytes)`（`0x8d80ff0a`）的调用，参数能用 Solidity 的 `abi.decode` 解出来。MultiSendCallOnly 本身也是这样解码参数的，两边对同一段 `data` 得到的字节相同。
- 解出来的批量交易能按第 3.3 节**完整、无残留**地解析。

**不放行**：MultiSend（非 CallOnly，它允许内层再 DELEGATECALL）、SignMessageLib、CreateCall、SafeMigration、SafeToL2Setup，以及其它任何地址。

这比 Signer 的 R01 更严格：R01 的白名单里还有 MultiSend。所以启用 Guard 的 Safe，Coordinator 只能用 MultiSendCallOnly 打包。

### 3.2 规则 2：哪些算"改配置"

**默认拒绝**：`to == self`、`operation == CALL` 且 `data.length > 0` 的调用，一律算配置调用，需要排期。不按选择器列白名单，原因有三：

- Safe 自身的 `authorized` 函数只有自己能调，正常交易本来就不需要调自己；
- 以后的 Safe 版本可能加新的 `authorized` 函数；
- 与 R02"对 Safe 自身任何不认识的调用也判红"一致。

已知会落到这里的选择器（供 Signer 解码和展示用）：

| 选择器 | 函数 | 版本 |
|---|---|---|
| `0x0d582f13` | `addOwnerWithThreshold(address,uint256)` | 全部 |
| `0xf8dc5dd9` | `removeOwner(address,address,uint256)` | 全部 |
| `0xe318b52b` | `swapOwner(address,address,address)` | 全部 |
| `0x694e80c3` | `changeThreshold(uint256)` | 全部 |
| `0x610b5925` / `0xe009cfde` | `enableModule(address)` / `disableModule(address,address)` | 全部 |
| `0xe19a9dd9` | `setGuard(address)` | 全部 |
| `0xf08a0323` | `setFallbackHandler(address)` | 全部 |
| `0xe068df37` | `setModuleGuard(address)` | 1.5.0 |
| `0xd4d9bdcd` | `approveHash(bytes32)` | 全部（self 不是 owner，会 GS030，但仍按默认拒绝处理） |

**不算**配置调用的情况：

- 对 self 的空 `data` 调用（只转 ETH 给自己）。
- 调 **Guard 合约自己**的函数（`schedule`、`cancel` 等，第 4、5 节）。这些调用必须始终放行，否则排期本身就做不了。

**配置调用可能藏在哪里**，以及 Guard 怎么覆盖：

| 途径 | 能否改配置 | Guard 的处理 |
|---|---|---|
| `execTransaction` 直接 CALL self | 能 | 规则 2 |
| DELEGATECALL MultiSendCallOnly，内层 CALL self | 能：内层调用的 `msg.sender` 是 self | 解析批量交易，内层只要有一条配置调用，**整笔外层交易**就按变更处理（3.3） |
| DELEGATECALL 任何其它合约 | 能：直接写存储 | 规则 1 拒绝 |
| 内层 CALL 到 MultiSendCallOnly（不是 DELEGATECALL） | 不能：那次调用里 `msg.sender` 是 MultiSendCallOnly，不是 self | 当普通调用放行 |
| 调第三方合约，再由它回调 Safe | 不能：`authorized` 要求 `msg.sender == self` | 放行 |
| 模块（`execTransactionFromModule`） | **能** | 1.3.0 / 1.4.1 管不到（第 7.3 节）；1.5.0 用 Module Guard 对模块交易执行同样的规则 1、2 |
| fallback handler | 不能直接改：它是被 CALL 的，不是被 DELEGATECALL；但它决定了 Safe 怎么回应 EIP-1271 和代币回调 | `setFallbackHandler` 属于配置调用 |
| `setup` | 只能在建 Safe 时调一次 | 不涉及 |

### 3.3 MultiSendCallOnly 批量交易的解析

格式：每条子交易是 `operation(1) ‖ to(20) ‖ value(32) ‖ dataLength(32) ‖ data(dataLength)`，首尾相接。Guard 的解析必须和 MultiSendCallOnly 的汇编**逐字节一致**，并且更严格：

- `operation` 必须是 0。MultiSendCallOnly 遇到 1 也会 revert，Guard 提前拒绝。
- **`to == 0` 当作 self。** 1.5.0 的 MultiSendCallOnly 会把 `to == 0` 换成 `address(this)`，在 DELEGATECALL 下就是 Safe 本身；1.3.0 / 1.4.1 会真的调 0 地址。三个版本统一按 self 处理，宁严勿松。
- 每条的长度必须正好落在批量数据之内，最后一条结束的位置必须正好等于总长度。截断、多余字节、`dataLength` 越界都直接拒绝。MultiSendCallOnly 对越界读取不检查，会读到内存里的垃圾数据，所以 Guard 不能比它松。
- 子交易数量设上限（例如 64），防止 Guard 的 gas 被放大。超过上限就拒绝，只影响这一笔交易。

只要有任一子交易是配置调用（`to ∈ {self, 0}` 且 `data` 非空），整笔外层交易就是一笔"变更"，`changeHash` 按**外层**的 `(to = MultiSendCallOnly, value, data, operation = DELEGATECALL)` 计算。同一批里的普通转账也跟着一起等待。这样排期和执行看到的是同一份字节，不需要逐条子交易记账。

### 3.4 Module Guard（只有 1.5.0）

`checkModuleTransaction(to, value, data, operation, module)` 的规则和 `checkTransaction` 相同：

- 规则 1 不变；
- 规则 2：模块发起的配置调用也要先排期，`changeHash` 的计算方式不变，所以同一个变更既可以由 owner 执行，也可以由模块执行；
- 返回值是 `changeHash`，没有配置调用时返回 0；`checkAfterModuleExecution` 什么都不做。

## 4. 排期与执行（规则 2 的记账）

### 4.1 为什么用变更内容，而不用 safeTxHash

safeTxHash 里包含 nonce。如果按 safeTxHash 排期，被排期的交易就绑定在 nonce N 上：

- 等待期内只要执行了任何别的交易，nonce 就会越过 N，排好的变更作废；
- 反过来，如果等待期内不能执行别的交易，日常转账就被卡 48 小时。

两种结果都不能接受。所以按 `changeHash = keccak256(abi.encode(self, to, value, keccak256(data), operation))` 排期，不含 nonce 和 gas、退款参数：

- `safeTxGas`、`baseGas`、`gasPrice`、`gasToken`、`refundReceiver` 不进 `changeHash`。执行那一笔仍然要凑够阈值的签名，签名覆盖这些字段，Signer 对它们也有规则（R12 等）。
- `chainId` 不进 `changeHash`。Guard 部署在每条链上，存储天然按链分开。

### 4.2 两步、两轮签名

1. **排期**：一笔普通的 Safe 交易，`CALL guard.schedule(to, value, data, operation)`。调用 Guard 自己属于第 3.2 节的放行项，所以这一笔不需要排期，但需要凑够阈值的签名。Guard 只接受 `msg.sender` 是 Safe 的 `schedule`，等于"Safe 同意排期"，其他人无法替某个 Safe 排期，也就没有刷存储的问题。
   - Guard 记录 `pending[self][changeHash] = {id, readyAt = now + DELAY}`，`id` 是这个 Safe 的排期计数器加 1。
   - 发出事件 `ChangeScheduled(self, changeHash, id, readyAt, to, value, data, operation)`。完整内容放进事件，是为了让监控方和 Signer 能还原出变更内容。
2. **执行**：`readyAt` 之后、`readyAt + GRACE` 之前，owner 再签一笔内容完全相同的 Safe 交易并执行。`GRACE` 例如 7 天，过期的排期作废，防止很久以前批准的变更被翻出来用。

两轮签名是有意为之：被骗签了排期的人，48 小时后还要再签一次执行，中间还有任何一个 owner 的否决。配置变更很少发生，这个代价可以接受。

### 4.3 执行时的核对

`checkTransaction` 识别出这是一笔变更后：

1. 计算 `changeHash`；
2. 读 `pending[self][changeHash]`；不存在、`now < readyAt` 或 `now ≥ readyAt + GRACE`，都 revert；
3. **在 `checkTransaction` 里直接删除这条排期**（消耗掉），发出 `ChangeExecuted`。

为什么在执行前就消耗，而不是等 `checkAfterExecution` 根据 `success` 再删：

- 我们的交易一律 `safeTxGas = 0`（R12）。这种情况下内层调用失败，`execTransaction` 会整体 revert，排期的删除也随之回滚，可以重试。
- 只有 `safeTxGas ≠ 0` 时，内层失败而外层成功，排期被白白消耗，这时重新排期即可。
- 这样 `checkAfterExecution` 不需要任何逻辑。"after 钩子永不 revert"对防止锁死很重要（第 6 节）。

### 4.4 重复提交

- 同一 `changeHash` 已经在排期中时，`schedule` 直接 revert，不刷新 `readyAt`。否则攻击者可以反复排期，把别人的变更无限推迟；而且已有的否决签名绑定的是 `id`，刷新后对不上。
- 排期被执行、取消或过期后，可以重新排期，得到新的 `id` 和 `readyAt`。
- 内容不同的多个变更可以同时排期，互不影响。

### 4.5 等待期（DELAY）

**每份部署写死一个常量**，例如 48 小时，可选范围限定在 [24 小时, 14 天]，用构造参数加检查。不提供按 Safe 修改等待期的接口，原因：

- "把等待期改短"本身就要防，否则又是一条要排期的变更，状态更多、攻击面更大；
- 想换等待期，就换一份 Guard。`setGuard(新地址)` 本身是一笔变更，按旧 Guard 的等待期执行。

## 5. 否决（规则 3）

### 5.1 EIP-712 结构

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
  name = "UniPass Inkan Guard", version = "1", chainId, verifyingContract = Guard 地址

Cancel(address safe,bytes32 changeHash,uint256 id)
```

- `id` 把否决绑定在**这一次**排期上：同样的内容以后重新排期会拿到新的 `id`，旧的否决签名不能拿来否决它，也就不会出现"预先签好一张否决、永远压着某个变更"的情况。
- domain 里有 `chainId` 和 Guard 地址，签名不能跨链、也不能拿到另一份 Guard 上使用。
- 不设过期时间：只要那次排期还在，否决就有效；排期一旦不在了，否决签名自然失效。

### 5.2 提交方式

`cancel(address safe, bytes32 changeHash, uint256 id, address owner, bytes signature)`，**任何人都可以调用**：

1. `pending[safe][changeHash].id == id`，否则 revert；
2. `ISafe(safe).isOwner(owner)` 为真，以执行当下的 owner 集合为准；
3. 验签，`digest` 是上面的 EIP-712 哈希：
   - `owner` 没有代码：按 ECDSA 验证。只接受 64 或 65 字节、`v ∈ {27, 28}`、low-s 的签名，并要求 `ecrecover(digest, v, r, s) == owner`；
   - `owner` 有代码：调 EIP-1271 `isValidSignature(bytes32 digest, bytes signature)`，要求返回 `0x1626ba7e`。我们的 WebAuthn proxy 支持这个接口（`docs/webauthn-signature.md`），WebAuthn 的 challenge 就是 `digest`。签名格式与 SafeTx 的完全一样，只是不再套 Safe 的签名打包；
4. 例外（5.4）检查通过；
5. 删除这条排期，发出 `ChangeCancelled(safe, changeHash, id, owner)`。

Safe 自己也可以发一笔普通交易调 `cancel` 取消，此时 `msg.sender == safe`，不需要 owner 签名。

谁来提交：我们的 owner 是 WebAuthn proxy，发不了交易，所以否决签名要交给一个能付 gas 的账户：外部 EOA owner、产品形态里讨论中的"提交账户"、或者任何愿意帮忙的人。提交者拿到否决签名后**只能取消**，做不了别的，所以把签名交给不信任的人也没关系。估算 gas：21k + 约 35k（WebAuthn 经 0x100 验签）+ 约 10k ≈ **6.5 万**。

### 5.3 Signer 怎么显示和解码

否决请求由 Coordinator 发给 Signer，走 `unipass-sign-request` 的新载荷类型。外部气隙钱包走 `eth-sign-request`，数据类型是 EIP-712 typed data。载荷包括 Guard 地址、chainId、safe、id、readyAt，以及**变更的完整内容** `(to, value, data, operation)`，不只是哈希。Signer：

1. 用完整内容重新计算 `changeHash`，和载荷里的值核对；
2. 检查 safe 在"我的 Safe"里、chainId 在白名单里，Guard 地址等于已知部署，任何一项不符就硬拒；
3. 用现有的解码器（`docs/decoding.md`）解出变更内容，按 F4 显示变更前后对比；
4. 标题写"否决：Safe ×× 的待生效变更 #id（将在 yyyy-mm-dd hh:mm 生效）"。否决本身没有风险，不判红，但仍然要确认，避免误点。

Signer 还要相应调整两类交易的显示：

- **排期交易**（`CALL guard.schedule(...)`）：这才是真正的决策点。要把内层变更解出来，按 R02 判红并显示 F4 对比，标题写"排期：48 小时后可以执行"。
- **执行交易**（变更本身）：照常按 R02 判红，并附上"已排期 #id，已于 … 到期"。这个信息由 Coordinator 提供，属于不可信输入，只作为说明；能否执行最终由链上的 Guard 判定。

### 5.4 防止一个作恶的 owner 用否决锁死 Safe

问题：任何一个 owner 都能否决，那么一个作恶（或被控制）的 owner 可以否决所有变更，**包括把他自己移除**，Safe 就永远改不了配置。

规则：**一个 owner 对"单纯移除自己"的变更的否决无效**。"单纯移除自己"指外层交易是 `CALL self`，`data` 是 `removeOwner(prev, owner, t)` 或 `swapOwner(prev, owner, new)`，且被移除的正是提交否决的这个 owner；批量交易一律不算。

- 作恶的 owner 可以被移除：其他人排期移除他，等过等待期执行，他否决不了；
- 不能借这个例外绕过否决：攻击者把"移除诚实的 X"和别的操作打包，就不算"单纯移除"，X 照样可以否决；如果是单纯移除 X，其他每一个 owner 都可以否决；
- 移除作恶 owner 之后，被他挡住的其它变更（例如卸 Guard）可以重新排期。
- 代价：如果唯一发现异常的恰好是被移除的 X，他否决不了自己的移除。他仍然可以在等待期内提醒其他 owner 去否决，但链上不再替他兜底。这是"防一个 owner 锁死 Safe"和"防所有人被骗"之间的取舍，列在第 12 节待定。

## 6. 不会把自己锁死

### 6.1 风险来源

`checkTransaction` 或 `checkAfterExecution` 只要 revert，那笔交易就执行不了。如果"卸掉 Guard"这笔交易也被拒，而 1.3.0 / 1.4.1 又没有模块，Safe 就**永久锁死**，资产也取不出来。

F4 说"Guard 必须始终放行 `setGuard(0)`"，而规则 2 要求卸 Guard 也要等待。二者的协调办法是：**`setGuard(0)` 始终可达，但不能立即执行**。立即放行等于把 Guard 白送给攻击者：先卸 Guard，再做 DELEGATECALL。

### 6.2 `checkTransaction` 的判断顺序

按以下顺序判断，前面的分支不依赖后面的任何代码：

| 顺序 | 条件 | 处理 | 依赖 |
|---|---|---|---|
| ① | `operation == CALL` 且 `to == Guard 自己` | 放行（`schedule`、`cancel`） | 无 |
| ② | `operation == CALL` 且 `to ∉ {self, 0}` | 放行（日常转账、合约调用） | 无 |
| ③ | `operation == CALL`、`to == self`、`value == 0`、`data == abi.encodeCall(setGuard, (0))`（恰好 36 字节） | 查 `pending[self][changeHash]`，核对等待期后放行并消耗 | **只读写一个存储槽，比较时间戳**。不解析数据，不调外部合约，不涉及白名单 |
| ④ | `operation == CALL`、`to == self`、`data` 为空 | 放行 | 无 |
| ⑤ | `operation == CALL`、`to == self`、其它 `data` | 按变更核对（4.3） | 同 ③ |
| ⑥ | `operation == DELEGATECALL` | 规则 1 → 解析（3.3）→ 有配置调用就按变更核对 | 白名单、ABI 解码、解析器 |
| ⑦ | 其它 `operation` 值 | revert | — |

- 1.5.0 的 Module Guard 也用同样的顺序。另外，`setModuleGuard(0)` 和 `setGuard(0)` 一样走 ③ 那样的最短路径。
- `checkAfterExecution` 和 `checkAfterModuleExecution` 是**空函数**。
- `schedule` 只做"检查重复 → 写存储 → 发事件"，不对内容做任何校验，保证 `setGuard(0)` 永远能排上。`cancel` 出 bug 最多导致否决不了，不会让交易执行不了。
- 合约不可升级、不能自毁、没有管理员，不存在"管理员误操作把所有 Safe 锁死"。

### 6.3 仍然存在的风险，以及应对

- **③ 这条路径本身有 bug**：这条路径只有十来行，用以下手段保证：
  - 形式化验证或符号执行（Halmos / Certora 一类工具），证明"排期后过了等待期，③ 一定不 revert"；
  - 差分模糊测试；
  - 外部审计。
- **等待期设错**：构造时检查范围 [24 小时, 14 天]，最坏情况是卸载要等 14 天，不会锁死。
- **白名单漏了以后的 MultiSendCallOnly 版本**：只会让 DELEGATECALL 不可用，可以拆成多笔 CALL 交易，或者排期换一份新 Guard，不会锁死。
- **所有 owner 的签名都拿不到**：这和 Guard 无关，没有 Guard 也一样（F5）。
- **1.3.0 / 1.4.1 上启用了模块**：模块不受 Guard 限制（7.3），这是绕过问题，不是锁死问题。Guard 不在 `checkTransaction` 里检查"是否有模块"并据此 revert，否则一旦有模块，Safe 就锁死了。

## 7. 安全分析

### 7.1 Guard 本身的攻击面

| 攻击面 | 说明 | 处理 |
|---|---|---|
| 解析器和 MultiSendCallOnly 不一致 | Guard 认为批量里没有配置调用，MultiSendCallOnly 实际却执行了一条 → 绕过规则 2 | 逐字节照搬汇编语义并且更严（3.3）；用真实的 MultiSendCallOnly 做差分模糊测试：同一段批量数据，比对 Guard 解析出的子交易和实际执行的调用 |
| `abi.decode` 和 MultiSendCallOnly 解码不一致 | 非规范的偏移、多余的尾部字节 | 两边都用 Solidity ABI 解码器（3.1）；测试覆盖非规范编码 |
| 排期刷存储 | — | 只有 Safe 自己能 `schedule`（4.2） |
| 否决签名重放 | 跨链、跨 Guard、跨排期 | domain 包含 chainId 和 Guard 地址，消息包含 `id`（5.1） |
| 冒充 Safe | 调用者传一个假的 `safe`，并让它的 `isOwner` 返回 true | 只有那个"Safe"自己排过期的内容才能被取消，伪造一个 Safe 只能影响它自己 |
| EIP-1271 回调重入 | `cancel` 调 owner 合约时可能被重入 | 先检查、后写入，并加重入锁；`cancel` 只会删除记录 |
| owner 合约耗尽 gas | 只影响提交否决的那笔交易 | — |
| 时间戳偏差 | 出块者只能调整几秒 | 相对 48 小时可以忽略 |
| 执行和否决在 `readyAt` 附近竞争 | 谁先上链谁生效 | Signer 和文档都提醒尽早否决；监控在排期时就报警（7.4） |
| 一个作恶的 owner 否决所有变更 | — | 5.4 |
| 不可升级 | Guard 有 bug 也修不了 | 排期换一份新 Guard；卸载路径单独保证（6） |

### 7.2 防得住的

- **Bybit 型攻击**：签名凑够了，DELEGATECALL 到恶意合约去改 `masterCopy` 或其它存储，被规则 1 直接拒绝。DELEGATECALL 到 MultiSend（非 CallOnly）再嵌套 DELEGATECALL 也被拒。
- **悄悄接管 Safe**：加攻击者为 owner、降阈值、换 fallback handler（让 Safe 对任意 EIP-1271 消息返回"有效"）、启用恶意模块、卸掉 Guard。这些都要排期等 48 小时，期间任何一个没被骗的 owner 可以否决，监控也能报警。
- **"先卸 Guard 再动手"**：卸 Guard 本身也要等待，也可以被否决。

### 7.3 防不住的

- **签名人被骗签了一笔普通交易**：转账、ERC-20 `approve` / `permit` 授权给攻击者、调用恶意合约（CALL）、NFT `setApprovalForAll` 等。这些都是 `CALL to ≠ self`，Guard 直接放行。这一类只能靠第一层（R03、R05、R06、R09 等）。可以考虑的扩展是收款人白名单或单笔限额，但会影响日常使用，不在这三条规则的范围内。
- **链下签名**：Safe 通过 EIP-1271 签的消息（Permit2、Seaport 订单、登录等）不经过 `execTransaction`，Guard 完全看不到。只能靠 Signer 的消息规则（R04，v1.1）。
- **1.3.0 / 1.4.1 上已经启用的模块**：模块交易不经过 Guard。在启用 Guard 之前就存在的模块，以及等过等待期、没被否决而启用的模块，都能绕过全部规则。这与以后可选的 4337 模式冲突：**在 1.4.1 上启用 Safe4337Module，Guard 就形同虚设**，只有 1.5.0 的 Module Guard 能覆盖模块交易。
- **所有 owner 都被控制或都被骗，并且 48 小时内没有任何人发现**：Guard 只是争取时间，需要至少一个诚实、在线的 owner，或者监控。
- **没有部署 Guard 的链**，或者建 Safe 时没设 Guard。

### 7.4 必须配套：监控

没有人看，等待期就没有意义。需要：

- Coordinator 订阅 `ChangeScheduled` 事件，联网时一启动就检查所有登记过的 Safe 有没有待生效的变更，醒目地提示，并一键生成否决请求；
- 文档建议用户另外设一个独立的链上告警（区块浏览器的地址监控等），不依赖 Coordinator。Coordinator 可能就是被控制的那一环。

## 8. 部署与启用

- **部署**：一份不可升级、没有管理员的 Guard 合约，构造参数只有 DELAY 和 GRACE。用确定性部署器（Safe Singleton Factory）部署，主网、Base、Sepolia 地址相同。所有 Safe 共用这一份，状态按 `msg.sender`（即 Safe 地址）隔离。
- **新 Safe（推荐）**：`setup(owners, threshold, to = MultiSendCallOnly 1.4.1, data = multiSend([CALL self setGuard(guard)]), fallbackHandler, ...)`，1.5.0 还要加一条 `setModuleGuard(guard)`。`setup` 时的 DELEGATECALL 不经过 Guard，内层 CALL self 的 `msg.sender` 是 Safe，满足 `authorized`。这和 `DeployTestSafe` 的部署方式兼容，仍然是一笔交易。好处是从第一个区块起就有 Guard，没有空窗。CREATE2 地址会因此变化，Signer 登记时用 setup 参数核对（S3 / S4），能看到"已启用 Guard"。
- **已有的 Safe**：一笔普通 Safe 交易 `CALL self setGuard(guard)`。启用的那一笔不经过 Guard，立即生效；启用之后，卸载就要等待了。
- 1.4.1 和 1.5.0 的 `setGuard` 会检查 ERC-165，Guard 必须实现 `supportsInterface`（第 1 节）。

## 9. gas 开销（估）

| 交易 | 额外开销（估） | 构成 |
|---|---|---|
| 普通转账（`execTransaction`，CALL 别人） | **约 +7k ~ +10k**，在 11.3 万的基础上约 +7%~9% | Safe 读 Guard 存储槽（冷读 2.1k）；CALL Guard 两次（冷 2.6k + 热 0.1k）；Safe 把全部参数 ABI 编码后传给 Guard，`signatures` 约 480 字节，复制和内存约 1.5k~3k；Guard 走分支 ② 直接返回 |
| MultiSendCallOnly 批量（无配置调用） | 上面的基础上，每条子交易 +约 0.3k~0.6k | ABI 解码、逐条解析 |
| 排期（`CALL guard.schedule`） | 约 +45k ~ +60k | 新写两个存储槽（约 44k）、事件里带上完整 `data` |
| 执行变更 | 约 +5k ~ +8k，删除存储槽还有部分退款 | 读写排期记录 |
| 否决（由别人提交） | 约 6.5 万整笔 | 5.2 |

这些按 Osaka 规则（当前主网）估算。Sepolia 的新分叉规则下，新写存储贵得多，排期那一笔会明显更贵（参考 `docs/webauthn-signature.md` 的 gas 一节）。实现后应当实测。

## 10. 对 Signer 和 Coordinator 的影响

- **Signer**：
  - 解码 `guard.schedule(...)`，把内层变更按 R02 判红并显示 F4 对比；
  - 新的否决签名请求类型，按 5.3 处理；
  - 执行变更时显示排期信息；
  - R01 在启用 Guard 的 Safe 上要更严（只接受 MultiSendCallOnly），避免用户签了一笔链上必然被拒的交易；
  - Guard 地址列入内置标签库。
- **Coordinator**：
  - 建 Safe 时可选"启用链上 Guard"；
  - 打包只用 MultiSendCallOnly；
  - 监控 `ChangeScheduled` 并提示；
  - 生成否决请求，把收到的否决签名交给外部 EOA owner 或提交账户提交；
  - 在 Safe 详情里显示待生效的变更和倒计时。

## 11. 工作量（粗估）

| 项 | 估计 |
|---|---|
| Guard 合约（约 400~600 行 Solidity，含 MultiSendCallOnly 解析、EIP-712、EIP-1271） | 3~5 天 |
| 测试：<br>• 单元测试；<br>• 三个 Safe 版本的 fork 测试；<br>• 解析器和真实 MultiSendCallOnly 的差分模糊测试；<br>• "过了等待期，卸载路径不 revert"的不变量或形式化证明；<br>• 用 WebAuthn proxy 签的否决；<br>• gas 基准；<br>• Bybit 重放 | 6~9 天 |
| 外部审计 | 1~2 周（需要预算；没有审计不建议给真实资产启用） |
| Signer：解码 `schedule`、否决请求类型、新规则和文案（中英） | 3~5 天 |
| Coordinator：启用开关、事件监控、否决流程、倒计时界面 | 4~6 天 |
| 文档和测试向量（否决的 EIP-712 向量，含 WebAuthn） | 1~2 天 |

合计约 **3~4 周工程量，另加审计**。只做文章里的演示（合约加 fork 测试，不改 App）约 1.5~2 周。

## 12. 待定

- DELAY 取 48 小时还是 72 小时（F4 写的是 24~72 小时）；GRACE 取 7 天是否合适。
- 是否需要"紧急通道"（例如阈值以上的 owner 一致同意时缩短等待）。这会削弱"所有签名人都被骗"这个场景下的保护，目前倾向不做。
- 5.4 的"不能否决单纯移除自己"是否保留，还是改成"移除自己需要更长的等待期"。
- 否决门槛是否可配置，例如"需要 2 个 owner 才能否决"，用来降低 5.4 那类骚扰。目前固定为 1，对应"只要有一个人没被骗"的设计目标。
- 与以后的 4337 模式如何共存：只在 1.5.0 + Module Guard 上同时启用；1.4.1 上二选一。
