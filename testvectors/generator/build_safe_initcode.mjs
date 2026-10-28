// 读各 SafeProxyFactory 的 proxyCreationCode()，算出 (factory, singleton) 的 CREATE2 init code hash。
// Signer 只内置这些哈希（不内置 LGPL 的代理字节码），用来离线核对 Safe 地址。需要联网，只在开发机上跑：node build_safe_initcode.mjs
import { createPublicClient, http, keccak256, encodePacked, toFunctionSelector, concatHex, padHex } from 'viem'
const RPC = { 1: 'https://ethereum-rpc.publicnode.com', 8453: 'https://base-rpc.publicnode.com', 11155111: 'https://ethereum-sepolia-rpc.publicnode.com' }
const factories = { '1.3.0 canonical': '0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2', '1.3.0 eip155': '0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC',
  '1.4.1': '0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67', '1.5.0': '0x14F2982D601c9458F93bd70B218933A6f8165e7b' }
const singletons = { 'GnosisSafe 1.3.0 canonical': '0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552', 'GnosisSafeL2 1.3.0 canonical': '0x3E5c63644E683549055b9Be8653de26E0B4CD36E',
  'GnosisSafe 1.3.0 eip155': '0x69f4D1788e39c87893C980c06EdF4b7f686e2938', 'GnosisSafeL2 1.3.0 eip155': '0xfb1bffC9d739B8D520DaF37dF666da4C687191EA',
  'Safe 1.4.1': '0x41675C099F32341bf84BFc5382aF534df5C7461a', 'SafeL2 1.4.1': '0x29fcB43b46531BcA003ddC8FCB67FFE91900C762',
  'Safe 1.5.0': '0xFf51A5898e281Db6DfC7855790607438dF2ca44b', 'SafeL2 1.5.0': '0xEdd160fEBBD92E350D4D398fb636302fccd67C7e' }
const sel = toFunctionSelector('proxyCreationCode()')
const out = { selector: sel, blocks: {}, factories: {} }
for (const [chain, url] of Object.entries(RPC)) {
  const c = createPublicClient({ transport: http(url) })
  out.blocks[chain] = Number(await c.getBlockNumber())
  for (const [name, f] of Object.entries(factories)) {
    const code = await c.getCode({ address: f })
    if (!code || code === '0x') { console.log(chain, name, 'NO CODE'); continue }
    const r = await c.call({ to: f, data: sel })
    // ABI: bytes
    const hex = r.data.slice(2)
    const len = parseInt(hex.slice(64, 128), 16)
    const creation = '0x' + hex.slice(128, 128 + len * 2)
    const h = keccak256(creation)
    out.factories[name] ??= { address: f, creationCodeHash: h, chains: [] }
    if (out.factories[name].creationCodeHash !== h) throw new Error(`mismatch ${name} on ${chain}`)
    out.factories[name].chains.push(Number(chain))
    out.factories[name].creation = creation
  }
}
const table = []
for (const [fname, f] of Object.entries(out.factories)) {
  for (const [sname, s] of Object.entries(singletons)) {
    table.push({ factory: f.address, factoryName: fname, singleton: s, singletonName: sname, chains: f.chains,
      initCodeHash: keccak256(concatHex([f.creation, padHex(s, { size: 32 })])) })
  }
}
for (const f of Object.values(out.factories)) delete f.creation
console.log(JSON.stringify({ ...out, table }, null, 1))
