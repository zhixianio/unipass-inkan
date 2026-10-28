// 用 viem 作为参考实现，生成 core/ 的测试向量。
// 随机数用固定种子，重新生成结果不变：`pnpm generate`。
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { concatHex, encodeAbiParameters, encodeFunctionData, encodePacked, getAddress, hashTypedData, keccak256, parseAbiItem, size, toHex } from 'viem'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..')

// xorshift32，只用于生成可复现的测试数据
let seed = 0x2f6b9c31
function nextU32() {
  seed ^= seed << 13; seed >>>= 0
  seed ^= seed >>> 17
  seed ^= seed << 5; seed >>>= 0
  return seed
}
function randomBytes(n) {
  const b = new Uint8Array(n)
  for (let i = 0; i < n; i++) b[i] = nextU32() & 0xff
  return b
}
function randomUint(maxBytes) {
  const n = nextU32() % (maxBytes + 1)
  if (n === 0) return 0n
  return BigInt(toHex(randomBytes(n)))
}
const randomAddress = () => getAddress(toHex(randomBytes(20)))
const pick = (arr) => arr[nextU32() % arr.length]

function write(name, value) {
  writeFileSync(join(outDir, name), JSON.stringify(value, null, 2) + '\n')
  console.log(`wrote ${name}`)
}

// keccak256：覆盖 rate（136 字节）边界附近的长度
write('keccak256.json', [0, 1, 31, 32, 135, 136, 137, 271, 272, 1000].map((len) => {
  const input = toHex(randomBytes(len))
  return { input, hash: keccak256(input) }
}))

// EIP-55 地址校验和
write('address.json', Array.from({ length: 20 }, () => {
  const checksummed = randomAddress()
  return { lower: checksummed.toLowerCase(), checksummed }
}))

// uint256 十进制 ↔ 32 字节大端
write('uint256.json', [0n, 1n, 2n ** 64n - 1n, 2n ** 64n, 2n ** 256n - 1n, ...Array.from({ length: 15 }, () => randomUint(32))]
  .map((v) => ({ decimal: v.toString(), bytes32: toHex(v, { size: 32 }) })))

// safeTxHash
const safeTxTypes = {
  SafeTx: [
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'data', type: 'bytes' },
    { name: 'operation', type: 'uint8' },
    { name: 'safeTxGas', type: 'uint256' },
    { name: 'baseGas', type: 'uint256' },
    { name: 'gasPrice', type: 'uint256' },
    { name: 'gasToken', type: 'address' },
    { name: 'refundReceiver', type: 'address' },
    { name: 'nonce', type: 'uint256' },
  ],
}
const zero = '0x0000000000000000000000000000000000000000'
write('safetx.json', Array.from({ length: 30 }, (_, i) => {
  const chainId = pick([1n, 10n, 8453n, 42161n, 11155111n, randomUint(8)])
  const safe = randomAddress()
  // 前几个是常见形态（无 gas 退款），后面字段全随机
  const simple = i < 10
  const message = {
    to: randomAddress(),
    value: randomUint(16),
    data: toHex(randomBytes(simple ? pick([0, 4, 68]) : nextU32() % 600)),
    operation: simple ? 0 : nextU32() % 2,
    safeTxGas: simple ? 0n : randomUint(8),
    baseGas: simple ? 0n : randomUint(8),
    gasPrice: simple ? 0n : randomUint(16),
    gasToken: simple ? zero : randomAddress(),
    refundReceiver: simple ? zero : randomAddress(),
    nonce: randomUint(simple ? 2 : 32),
  }
  const hash = hashTypedData({
    domain: { chainId, verifyingContract: safe },
    types: safeTxTypes,
    primaryType: 'SafeTx',
    message,
  })
  return {
    chainId: chainId.toString(),
    safe,
    tx: {
      ...message,
      value: message.value.toString(),
      safeTxGas: message.safeTxGas.toString(),
      baseGas: message.baseGas.toString(),
      gasPrice: message.gasPrice.toString(),
      nonce: message.nonce.toString(),
    },
    safeTxHash: hash,
  }
}))

// WebAuthn signer proxy 的签名 ABI 编码：abi.encode(bytes, string, uint256, uint256)
write('webauthn-abi.json', Array.from({ length: 10 }, (_, i) => {
  const authenticatorData = toHex(randomBytes(i === 0 ? 37 : 37 + (nextU32() % 80)))
  const clientDataFields = i === 0
    ? '"origin":"unipass-signer://secure-enclave","crossOrigin":false'
    : `"origin":"https://example.test/${toHex(randomBytes(nextU32() % 40)).slice(2)}"`
  const r = BigInt(toHex(randomBytes(32)))
  const s = BigInt(toHex(randomBytes(32)))
  return {
    authenticatorData,
    clientDataFields,
    r: toHex(r, { size: 32 }),
    s: toHex(s, { size: 32 }),
    encoded: encodeAbiParameters(
      [{ type: 'bytes' }, { type: 'string' }, { type: 'uint256' }, { type: 'uint256' }],
      [authenticatorData, clientDataFields, r, s],
    ),
  }
}))

// ---- 交易解码 ----

// 已识别函数的调用数据（viem encodeFunctionData）。args 里的整数用十进制字符串，bool 用 true/false。
const SAFE = '0x8ceb01112162b035BE3D38740f8233d28DA0E4a1'
const PERMIT2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3'
const functionSpecs = [
  ['function transfer(address to, uint256 amount)', 'any'],
  ['function transferFrom(address from, address to, uint256 amount)', 'any'],
  ['function approve(address spender, uint256 amount)', 'any'],
  ['function increaseAllowance(address spender, uint256 addedValue)', 'any'],
  ['function decreaseAllowance(address spender, uint256 subtractedValue)', 'any'],
  ['function setApprovalForAll(address operator, bool approved)', 'any'],
  ['function safeTransferFrom(address from, address to, uint256 tokenId)', 'any'],
  ['function safeTransferFrom(address from, address to, uint256 tokenId, bytes data)', 'any'],
  ['function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)', 'any'],
  ['function approve(address token, address spender, uint160 amount, uint48 expiration)', 'permit2'],
  ['function addOwnerWithThreshold(address owner, uint256 _threshold)', 'safe'],
  ['function removeOwner(address prevOwner, address owner, uint256 _threshold)', 'safe'],
  ['function swapOwner(address prevOwner, address oldOwner, address newOwner)', 'safe'],
  ['function changeThreshold(uint256 _threshold)', 'safe'],
  ['function enableModule(address module)', 'safe'],
  ['function disableModule(address prevModule, address module)', 'safe'],
  ['function setGuard(address guard)', 'safe'],
  ['function setModuleGuard(address moduleGuard)', 'safe'],
  ['function setFallbackHandler(address handler)', 'safe'],
]
function randomArg(type) {
  if (type === 'address') return randomAddress()
  if (type === 'bool') return nextU32() % 2 === 0
  if (type === 'bytes') return toHex(randomBytes(nextU32() % 70))
  const bits = Number(type.slice(4))
  return randomUint(bits / 8)
}
const showArg = (v) => (typeof v === 'bigint' ? v.toString() : v)
const calls = []
for (const [sig, scope] of functionSpecs) {
  const item = parseAbiItem(sig)
  for (let i = 0; i < 4; i++) {
    const args = item.inputs.map((p) => randomArg(p.type))
    const to = scope === 'safe' ? SAFE : scope === 'permit2' ? PERMIT2 : randomAddress()
    calls.push({
      signature: `${item.name}(${item.inputs.map((p) => p.type).join(',')})`,
      to,
      args: args.map(showArg),
      calldata: encodeFunctionData({ abi: [item], functionName: item.name, args }),
    })
  }
}

// MultiSend：打包格式 operation(uint8) ‖ to(address) ‖ value(uint256) ‖ dataLength(uint256) ‖ data。
const multiSendAbi = parseAbiItem('function multiSend(bytes transactions)')
const packTx = (t) => encodePacked(['uint8', 'address', 'uint256', 'uint256', 'bytes'], [t.operation, t.to, t.value, BigInt(size(t.data)), t.data])
const multiSendCall = (txs) => encodeFunctionData({ abi: [multiSendAbi], functionName: 'multiSend', args: [concatHex(txs.map(packTx))] })
const MULTISEND_141 = '0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526'
const multiSends = Array.from({ length: 6 }, (_, i) => {
  const txs = Array.from({ length: 1 + (nextU32() % 5) }, () => {
    const kind = nextU32() % 3
    const item = parseAbiItem(functionSpecs[nextU32() % 9][0])
    return {
      operation: 0,
      to: randomAddress(),
      value: kind === 0 ? randomUint(12) : 0n,
      data: kind === 0 ? '0x' : kind === 1 ? encodeFunctionData({ abi: [item], functionName: item.name, args: item.inputs.map((p) => randomArg(p.type)) }) : toHex(randomBytes(nextU32() % 40)),
    }
  })
  // 最后一个用例：嵌套一层 MultiSend（内层用 DELEGATECALL 调 MultiSend 1.4.1）
  if (i === 5) txs.push({ operation: 1, to: MULTISEND_141, value: 0n, data: multiSendCall(txs.slice(0, 2)) })
  return {
    multiSend: MULTISEND_141,
    calldata: multiSendCall(txs),
    txs: txs.map((t) => ({ operation: t.operation, to: t.to, value: t.value.toString(), data: t.data })),
  }
})

// SafeTx 的 EIP-712 JSON：按我们的规范序列化（键顺序固定、uint256 十进制字符串、EIP-55 地址），
// 用 viem 的 hashTypedData 算哈希，供 Swift 对拍序列化和哈希。
const typedData = Array.from({ length: 8 }, (_, i) => {
  const chainId = pick([1n, 8453n, 11155111n])
  const message = {
    to: randomAddress(),
    value: randomUint(i < 4 ? 0 : 16),
    data: toHex(randomBytes(nextU32() % 100)),
    operation: nextU32() % 2,
    safeTxGas: randomUint(i < 4 ? 0 : 4),
    baseGas: randomUint(i < 4 ? 0 : 4),
    gasPrice: randomUint(i < 4 ? 0 : 8),
    gasToken: i < 4 ? zero : randomAddress(),
    refundReceiver: i < 4 ? zero : randomAddress(),
    nonce: randomUint(2),
  }
  const safe = randomAddress()
  const json = JSON.stringify({
    types: { EIP712Domain: [{ name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }], SafeTx: safeTxTypes.SafeTx },
    primaryType: 'SafeTx',
    domain: { chainId: Number(chainId), verifyingContract: safe },
    message: Object.fromEntries(Object.entries(message).map(([k, v]) => [k, typeof v === 'bigint' ? v.toString() : v])),
  })
  return { json, safeTxHash: hashTypedData({ domain: { chainId, verifyingContract: safe }, types: safeTxTypes, primaryType: 'SafeTx', message }) }
})

write('decoding.json', { calls, multiSends, typedData })
