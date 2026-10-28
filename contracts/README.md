# contracts

Foundry 项目：验证 Signer 的 WebAuthn 签名能被 safe-modules `SafeWebAuthnSignerProxy` 和 Safe 接受，产出测试向量和 gas 数据。只调用上游合约，不修改。结论见 [docs/webauthn-signature.md](../docs/webauthn-signature.md)。

```bash
git submodule update --init --recursive
forge test                             # 本地：源码构建的 Safe 1.4.1 + passkey v0.2.1；fork 测试自动跳过
SEPOLIA_RPC_URL=<url> forge test -vv   # 加上 Sepolia fork（Safe 1.3.0 / 1.4.1 / 1.5.0 正式部署）和 gas 输出
forge script script/GenerateWebAuthnVectors.s.sol   # 重新生成 ../testvectors/webauthn/*.json
```

| 路径 | 内容 |
|---|---|
| `src/WebAuthnEncoding.sol` | Signer 端编码的独立实现（authenticatorData、clientDataJSON、签名消息、low-s、ABI 编码） |
| `src/SafeSignatures.sol` | 把 EOA / 合约签名排序打包成 Safe `signatures` |
| `src/PasskeyDeployments.sol` | passkey v0.2.1 规范地址、proxy creation code、离线算 signer 地址 |
| `src/SafeDeployments.sol` | Safe 1.3.0 / 1.4.1 / 1.5.0 规范地址 |
| `test/SafeWebAuthnBehaviour.sol` | 正例、反例、未部署 owner、一笔交易部署（每个部署都跑一遍） |
| `test/WebAuthnGas.t.sol` | gas 基准 |
| `test/WebAuthnEncoding.t.sol` | 与 safe-modules `WebAuthn` 库模糊对拍；核对已提交的测试向量 |
| `test/PasskeyCanonical.t.sol` | fork：src 里的常量和链上一致 |
| `script/GenerateWebAuthnVectors.s.sol` | 生成测试向量 |
| `script/DeployTestSafe.s.sol` | 在 Sepolia 部署测试 Safe（见下） |

## 在 Sepolia 部署测试 Safe

部署内容：**一笔交易**，发给 MultiSendCallOnly 1.4.1，依次做两件事：

1. 部署 Signer 的 WebAuthn proxy。公钥取自 `testvectors/webauthn/device/signer-key.json`（`xyz.unipass.signer` 的 SE 密钥），verifiers 用规范值，地址固定为 `0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06`。
2. 部署一个 SafeL2 1.4.1：2-of-2，owner 是这个 proxy 和你的 EOA。用 SafeL2，是因为 Safe Transaction Service 在 L2 和测试网上按事件索引。

脚本只通过 Foundry keystore（`--account`）签名，不读任何私钥环境变量。每一步都在你自己的终端里执行。

**0. 准备**（只做一次）

```bash
cd contracts
git submodule update --init --recursive
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
```

**1. 准备一个专用测试 EOA**：不要用存有真实资产的钱包。下面两种方式二选一，都会提示你设置 keystore 密码。

新建一个：

```bash
cast wallet new unipass-sepolia
```

或导入已有的测试私钥，私钥在提示里输入，不会留在 shell 历史中：

```bash
cast wallet import unipass-sepolia --interactive
```

keystore 由 Foundry 加密保存在你本机，不在仓库里。查看地址：

```bash
cast wallet address --account unipass-sepolia
```

**2. 领 Sepolia 测试 ETH**：0.01 ETH 就足够。可以用 Google Cloud Web3 Faucet（https://cloud.google.com/application/web3/faucet/ethereum/sepolia）或 PoW faucet（https://sepolia-faucet.pk910.de）。确认余额：

```bash
cast balance $(cast wallet address --account unipass-sepolia) --rpc-url $SEPOLIA_RPC_URL --ether
```

**3. 模拟**：不发交易，会要求输入 keystore 密码，打印预测的 Safe 和 proxy 地址，以及 gas 和所需 ETH：

```bash
forge script script/DeployTestSafe.s.sol --rpc-url $SEPOLIA_RPC_URL --account unipass-sepolia --evm-version amsterdam
```

**4. 实际部署**：与第 3 步同一条命令，加上 `--broadcast`：

```bash
forge script script/DeployTestSafe.s.sol --rpc-url $SEPOLIA_RPC_URL --account unipass-sepolia --evm-version amsterdam --broadcast
```

**必须带 `--evm-version amsterdam`**：Sepolia 从 2026-10-06 起运行比 Osaka 更新的分叉，部署合约的 gas 贵得多，而 `foundry.toml` 默认按 Osaka 模拟（与当前主网一致）。不带这个参数，Forge 会把 gas limit 估低，交易上链后因 proxy 部署 out of gas 而失败。2026-10-25 第一次部署就这样失败过一次（`0xd24d24be…b3f4`）。

gas：实际消耗 1,947,233（交易 `0xa9e27b58…c7cb`），Forge 给的 gas limit 约 285 万。按 Sepolia 当时 0.05 gwei 的 gas price，费用约 0.0001 ETH；即使涨到 20 gwei 也只要约 0.06 ETH。

**5. 记下部署结果**：脚本最后的 "Deployment summary" 一段里有（把它加进桌面端的 `KnownSafes.swift` 时要用，见 `apps/coordinator/README.md`）：

- Safe 地址
- signer proxy 地址
- EOA owner 地址
- 交易哈希：Forge 输出的 `[Success] Hash: 0x…` 一行，也可以用下面的命令取：

  ```bash
  jq -r '.transactions[0].hash' broadcast/DeployTestSafe.s.sol/11155111/run-latest.json
  ```

  在 `https://sepolia.etherscan.io/tx/<hash>` 可以查看。

补充：

- 新 Safe 里没有 ETH。STS 的提案和确认不需要它；要真正执行交易时，先往 Safe 转一点 ETH。
- 同样的 owner 再部署一个 Safe：在命令前加 `SAFE_SALT_NONCE=1`。重复部署同一个 Safe，脚本会直接报错退出。
- 已部署的实例（2026-10-25，一次性测试 EOA）：Safe `0x8ceb01112162b035BE3D38740f8233d28DA0E4a1`，signer proxy `0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06`，EOA owner `0x938313A557B6129d2D8CbDa84aD962B1869AB39a`，交易 `0xa9e27b58c413f7a31accb0af43d8a8dca4ec46fcf96a690068982c45f574c7cb`。
- `test/DeployTestSafe.t.sol` 在 Sepolia fork 上演练这个脚本（需要设置 `SEPOLIA_RPC_URL`），并核对地址与离线计算一致。

依赖（git submodule，固定版本）：`lib/safe-smart-account` @ `v1.4.1`、`lib/safe-modules` @ `passkey/v0.2.1`、`lib/forge-std` @ `v1.17.0`。上游合约源码为 LGPL-3.0-only（passkey npm 包标 GPL-3.0，按 GPL 对待）；本目录自己的代码为 Apache-2.0；`src/PasskeyDeployments.sol` 内嵌了 safe-modules 的编译字节码，沿用 LGPL-3.0-only（见仓库根目录的 NOTICE）。
