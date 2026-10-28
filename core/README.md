# UniPassCore

Signer（iOS，离线）和 Coordinator（macOS）共用的 Swift package。

**规则：这里只放纯计算代码。** Signer 会链接它，所以不能依赖 URLSession、Network、CFNetwork 或任何会联网的库；RPC、STS 客户端等放在 Coordinator 自己的 package 里。

## 现有内容

| 文件 | 内容 |
|---|---|
| `Keccak.swift` | Keccak-256 |
| `UInt256.swift` | 256 位无符号整数（解析、32 字节编码、比较、减法） |
| `Address.swift` | 地址解析、EIP-55 校验和、ABI 编码 |
| `SafeTx.swift` | SafeTx 的 EIP-712 hashStruct、domain separator、safeTxHash（Safe ≥1.3.0） |
| `WebAuthnSignature.swift` | Signer 手工拼的 WebAuthn 断言、签名消息、low-s 规范化、signer proxy 的 ABI 编码（格式见 `docs/webauthn-signature.md`，M0 已验证） |
| `SafeSignatures.swift` | 把 EOA / 合约 owner 签名打包成 `execTransaction` 的 `signatures` |
| `UR/CBOR.swift` | CBOR 编解码：编码确定性，解码默认从严（拒绝重复键、未排序键、非最短编码、不定长、浮点、非 NFC 文本、尾随字节），限制大小、深度、元素数 |
| `UR/Bytewords.swift`、`UR/UR.swift` | bytewords（minimal）、CRC32、`ur:` 字符串的单帧和多帧格式 |
| `UR/Fountain.swift` | 多帧喷泉码的编码和解码（和 URKit / bc-ur 逐字节一致），解码有消息大小、分片数、帧数上限 |
| `UR/EIP4527.swift` | `eth-sign-request`、派生路径 |
| `UR/UniPassURTypes.swift` | 自定义 UR 类型：`unipass-pairing`、`unipass-signature`、`unipass-safe`（格式见 `docs/ur-types.md`） |
| `Decoding/StrictJSON.swift` | 严格 JSON 读取（大小、深度、元素数上限，拒绝重复键） |
| `Decoding/SafeTxRequest.swift` | 从 `eth-sign-request` 的 EIP-712 JSON 解析 SafeTx：只接受唯一的规范序列化，safeTxHash 由我们重算 |
| `Decoding/ABIDecoder.swift` | 边界检查完备的 ABI 编解码，只接受标准编码（解码后重编码必须逐字节相同） |
| `Decoding/CallDecoder.swift` | 识别 ERC-20 / 721 / 1155、Permit2、Safe 自身的管理调用；拆 MultiSend / MultiSendCallOnly，限制嵌套和调用数；三条链上的 Safe 规范部署地址（说明见 `docs/decoding.md`） |
| `Rules/RiskModel.swift`、`Rules/RiskEngine.swift` | 风控规则 R01–R03、R05–R09 和硬拒（Safe 没登记、解码问题、裸哈希、联网）；输出 `RiskAssessment`，可越过的发现项和硬拒在类型上分开（说明见 `docs/rules.md`） |
| `Rules/Signable.swift` | 签名入口的闸门：`SignableTransaction` 只能从没被拒的评估构造，challenge 取重算的 safeTxHash；红色要输入确认短语 |
| `Rules/OwnerChangePreview.swift` | 改 owner / 门限时的变更前后对比 |
| `SafeAddress.swift` | 用 setup 参数离线按 CREATE2 重算 Safe 地址（登记 Safe 时核对） |
| `Rules/Explanation.swift`、`Resources/Localizable.xcstrings` | 中英双语白话解释模板；外部字符串只当数据引用 |
| `Rules/LabelLibrary.swift`、`Resources/labels.json` | 内置标签库：Safe 官方合约、Permit2、已核实的代币，每条注明来源（由 `testvectors/generator/build_labels.py` 生成） |

## 测试

```bash
swift test
```

参考向量在仓库根目录的 `testvectors/`：
- 以太坊相关的由 viem 生成（`testvectors/generator`，`pnpm install && pnpm generate`，固定种子，结果可复现）；
- UR 的取自 Blockchain Commons 和 Keystone 的公开测试数据（`testvectors/ur/`，来源和许可证见其中的 README）。
