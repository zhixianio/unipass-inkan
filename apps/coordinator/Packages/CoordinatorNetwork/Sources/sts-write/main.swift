import Foundation
import SafeTransactionService
import UniPassCore

// 测试网写操作（只在测试 Safe 上用）：
//
// sts-write hash    --safe S --to T [--value 0] [--data 0x] --nonce N
//                   打印 safeTxHash（core 本地计算）
// sts-write propose --safe S --to T [--value 0] [--data 0x] --nonce N --sender A
//                   (--eoa-sig 0x<65 字节> | --contract-sig 0x<proxy 签名>)
//                   发起提案；合约签名会包成 CONTRACT_SIGNATURE（owner = sender）
// sts-write confirm --hash H (--eoa-sig 0x… | --owner A --contract-sig 0x…)
//                   追加确认
// sts-write show    --hash H
// sts-write signatures --hash H
//                   从 STS 的确认拼出 execTransaction 的 signatures（core 的 SafeSignatures.encode）
//
// 全部加 [--chain sep]。EOA 签名可以用 `cast wallet sign --no-hash <safeTxHash>` 得到（v = 27/28）。

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func orFail<T>(_ value: T?, _ message: String) -> T {
    guard let value else { fail(message) }
    return value
}

func required(_ name: String) -> String {
    orFail(option(name), "缺少 --\(name)")
}

func address(_ name: String) -> Address {
    orFail(Address(hex: required(name).lowercased()), "--\(name) 不是地址")
}

func bytes(_ name: String) -> Data {
    orFail(Data(hex: required(name)), "--\(name) 不是十六进制")
}

guard let chain = SafeChain.known.first(where: { $0.shortName == (option("chain") ?? "sep") }) else { fail("未知链") }
let client = STSClient(chain: chain, apiKey: SafeAPIKey.resolve())

func transaction() -> (Address, SafeTx) {
    let tx = SafeTx(
        to: address("to"),
        value: orFail(UInt256(decimal: option("value") ?? "0"), "--value 不是十进制整数"),
        data: orFail(Data(hex: option("data") ?? "0x"), "--data 不是十六进制"),
        nonce: orFail(UInt256(decimal: required("nonce")), "--nonce 不是十进制整数")
    )
    return (address("safe"), tx)
}

/// `--eoa-sig` 原样提交；`--contract-sig` 按 owner 包成合约签名。
func signature(owner: Address) -> Data {
    if option("eoa-sig") != nil {
        let sig = bytes("eoa-sig")
        guard sig.count == 65 else { fail("EOA 签名必须是 65 字节") }
        return sig
    }
    return STSSignature.contract(owner: owner, signature: bytes("contract-sig"))
}

func show(_ safeTxHash: Data) async throws {
    let tx = try await client.multisigTransaction(safeTxHash: safeTxHash)
    print("STS：nonce \(tx.nonce)，确认 \(tx.confirmations?.count ?? 0)/\(tx.confirmationsRequired)，proposer \(tx.proposer ?? "—")，trusted \(tx.trusted.map(String.init) ?? "—")")
    for c in tx.confirmations ?? [] {
        print("  \(c.owner) \(c.signatureType ?? "?") \(c.signature.map { "\($0.prefix(20))…（\(($0.count - 2) / 2) 字节）" } ?? "")")
    }
}

do {
    switch args.first {
    case "hash":
        let (safe, tx) = transaction()
        print(tx.hash(chainId: UInt256(chain.chainId), safe: safe).hexString)
    case "propose":
        let (safe, tx) = transaction()
        let sender = address("sender")
        let hash = try await client.propose(safe: safe, transaction: tx, sender: sender, signature: signature(owner: sender), origin: "UniPass Inkan Desktop M0")
        print("已提交提案 \(hash.hexString)")
        try await show(hash)
    case "confirm":
        let hash = bytes("hash")
        let sig = option("eoa-sig") != nil ? signature(owner: .zero) : signature(owner: address("owner"))
        try await client.confirm(safeTxHash: hash, signature: sig)
        print("已追加确认")
        try await show(hash)
    case "show":
        try await show(bytes("hash"))
    case "signer":
        // RPC 核对 WebAuthn signer proxy 地址：sts-write signer --factory F --x X --y Y --verifiers V
        let rpc = EthRPC(url: orFail(EthRPC.defaultURL(chainID: chain.chainId), "没有默认 RPC"))
        print(try await rpc.webAuthnSigner(factory: address("factory"), x: bytes("x"), y: bytes("y"), verifiers: bytes("verifiers")).checksummed)
    case "safe":
        let rpc = EthRPC(url: orFail(EthRPC.defaultURL(chainID: chain.chainId), "没有默认 RPC"))
        let safe = address("safe")
        print("nonce \(try await rpc.safeNonce(safe))，threshold \(try await rpc.safeThreshold(safe))，owners \(try await rpc.safeOwners(safe).map(\.checksummed))")
    case "balances":
        // 余额和手续费：sts-write balances --safe S
        let rpc = EthRPC(url: orFail(EthRPC.defaultURL(chainID: chain.chainId), "没有默认 RPC"))
        let safe = address("safe")
        print("ETH \(try await rpc.balance(of: safe))")
        print("USDC \(try await rpc.tokenBalance(token: Address(hex: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")!, owner: safe))")
        print("baseFee \(try await rpc.baseFee())，tip \(try await rpc.maxPriorityFeePerGas())，gasPrice \(try await rpc.gasPrice())")
        print("nonce(EOA) \(try await rpc.transactionCount(Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!))")
        print("receipt \(String(describing: try await rpc.receipt("0xfb2148dfb0a8761abedbb0508b2c8d01c98b9ecdc86a55f9f3d325199be21252")?.succeeded))")
    case "signatures":
        // 从 STS 的确认拼出 execTransaction 的 signatures。
        let tx = try await client.multisigTransaction(safeTxHash: bytes("hash"))
        print(try SafeSignatures.encode(tx.ownerSignatures()).hexString)
    default:
        fail("用法见 Sources/sts-write/main.swift 顶部")
    }
} catch STSError.http(let status, let body) {
    fail("HTTP \(status)：\(body)")
} catch {
    fail("错误：\(error)")
}
