# 交易解码

> 实现在 `core/Sources/UniPassCore/Decoding/`，测试在 `core/Tests/UniPassCoreTests/DecodingTests.swift`，参考向量由 viem 生成（`testvectors/decoding.json`）。

Signer 收到签名请求后自己解码，不依赖 Coordinator 的任何描述。流程：

1. `eth-sign-request` → `SafeTxRequest(signRequest:)`：严格解析 EIP-712 JSON（格式见 `docs/ur-types.md`「SafeTx 的 EIP-712 JSON」），重算 safeTxHash。任何一处不符都是**硬拒**。
2. `DecodedSafeTx(request)` → `CallDecoder`：识别调用数据，展开 MultiSend。解码本身不会失败；不能执行或编码不规范的地方记为 `CallAction.invalid(DecodingProblem)`，规则层（块 3）把它们一律判为硬拒。

## 识别的函数

选择器由签名字符串用 keccak256 算出，不手写；viem 的 `encodeFunctionData` 生成的调用数据逐个对拍。

| 类别 | 函数 | 在哪个地址上识别 |
|---|---|---|
| ERC-20 | `transfer`、`approve`、`increaseAllowance`、`decreaseAllowance` | 任何地址 |
| ERC-20 / ERC-721 | `transferFrom(address,address,uint256)`：两种标准用同一个选择器，第三个参数可能是数量也可能是 tokenId，解码结果不区分，由规则 / 标签库判断 | 任何地址 |
| ERC-721 / ERC-1155 | `setApprovalForAll`；ERC-721 `safeTransferFrom` 带或不带 `bytes`；ERC-1155 `safeTransferFrom(address,address,uint256,uint256,bytes)` | 任何地址 |
| Permit2 | `approve(address token, address spender, uint160 amount, uint48 expiration)` | 只在规范 Permit2 地址 `0x000000000022D473030F116dDEE9F6B43aC78BA3`（Uniswap/permit2 `test/utils/DeployPermit2.sol`，MIT） |
| Safe 自身 | `addOwnerWithThreshold`、`removeOwner`、`swapOwner`、`changeThreshold`、`enableModule`、`disableModule`、`setGuard`、`setModuleGuard`（1.5.0 起）、`setFallbackHandler` | 只在 `to == 这个 Safe` 时（包括 MultiSend 1.5.0 里零地址被换成 Safe 的情况） |

别的地址上出现 Safe / Permit2 的选择器按"不认识的函数"处理。

**参数必须是标准 ABI 编码**：解码后重新编码必须逐字节相同。地址高位不为零、`uintN` 超宽（例如 Permit2 的 uint160 / uint48）、bool 不是 0/1、动态参数偏移不标准、`bytes` 补零不为零、末尾有多余字节，都记为 `malformedArguments`。Solidity 自己的解码器会忽略多余字节，我们不跟进：多出来的字节没有正当用途。

## MultiSend

只认 Safe 官方部署的 MultiSend / MultiSendCallOnly（`SafeDeployments.multiSendContracts`，来源 safe-global/safe-deployments commit `8e200b0`，MIT），而且只在首发链 1、8453、11155111 上：

| 版本 | MultiSend | MultiSendCallOnly |
|---|---|---|
| 1.3.0 canonical | `0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761` | `0x40A2aCCbd92BCA938b02010E17A5b8929b49130D` |
| 1.3.0 eip155 | `0x998739BFdAAdde7C933B942a68053933098f9EDa` | `0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B` |
| 1.4.1 | `0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526` | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| 1.5.0 | `0x218543288004CD07832472D464648173c77D7eB7` | `0xA83c336B20401Af773B6219BA5027174338D1836` |

三条链上 `networkAddresses` 完全相同：1.3.0 两份都有，1.4.1 / 1.5.0 只有 canonical。

打包格式（对照合约源码 `libraries/MultiSend.sol`）：`operation(1) ‖ to(20) ‖ value(32) ‖ dataLength(32) ‖ data`，逐条相接。合约源码里的几处行为决定了解码规则：

| 合约行为 | 解码规则 |
|---|---|
| MultiSend 要求被 DELEGATECALL 调用（`require(address(this) != MULTISEND_SINGLETON)`）；MultiSendCallOnly 被 CALL 调用时内部调用的 msg.sender 是它自己而不是 Safe | 用 CALL 调这两个合约记为 `multiSendViaCall` |
| operation 不是 0 / 1 时 revert | `invalidInnerOperation` |
| MultiSendCallOnly 里遇到 DELEGATECALL 就 revert | `delegateCallInCallOnly` |
| **1.5.0** 起 `to := or(to, mul(iszero(to), address()))`：零地址表示 Safe 自己；1.3.0 / 1.4.1 没有这一行 | 只在 1.5.0 的两个合约里把零地址换成 Safe（`DecodedCall.to`；原值留在 `rawTo`） |
| 合约按 `dataLength` 往后读，末尾不完整时会读到内存里的其它数据 | 数据必须正好用完，截断或多余都记为 `malformedMultiSend` |

嵌套：MultiSend 里可以再 DELEGATECALL 一个 MultiSend。最多 3 层、展开后最多 128 条调用（`CallDecoder.Limits`），超过记为 `nestingTooDeep` / `tooManyCalls`。

## 输出

`DecodedCall` 是一棵树：每个节点有 operation、实际 `to`、`rawTo`、value、data 和 `CallAction`（`.plain` 无调用数据、`.known`、`.multiSend`、`.unknown(selector)`、`.invalid(problem)`）。`flattened` 深度优先展开，`problems` 收集所有 `.invalid`。DELEGATECALL 到非 MultiSend 地址照常解码，是否判红由规则层（R01）决定。

## 测试

- viem：19 个函数各 4 组随机参数的调用数据、6 个 MultiSend（含一层嵌套）、8 个 EIP-712 JSON 和哈希。
- 手写反例：JSON 的每一种不规范写法、ABI 的每一种不标准编码、MultiSend 的每一种问题、1.5.0 与 1.4.1 的零地址差异、链白名单。
- 固定种子模糊测试：JSON 5000 次变异（通过的只能是规范序列化本身）；调用数据 3000 次变异（不崩溃，展开条数不超过上限）。
