import Foundation
import SafeTransactionService
import UniPassCore

// sts-probe [--chain sep] <safe 地址>
//
// 只读：about、Safe 信息、最近的多签交易；对每笔交易用 core 重算 safeTxHash，和 STS 返回的对拍。
// API key 从环境变量 SAFE_API_KEY 或 Keychain 读；没有也能跑（限 2 RPS）。

let args = Array(CommandLine.arguments.dropFirst())
var chain = SafeChain.sepolia
var positional: [String] = []
var i = 0
while i < args.count {
    if args[i] == "--chain", i + 1 < args.count {
        guard let c = SafeChain.known.first(where: { $0.shortName == args[i + 1] }) else {
            print("未知链 \(args[i + 1])，可选：\(SafeChain.known.map(\.shortName).joined(separator: " "))")
            exit(1)
        }
        chain = c
        i += 2
    } else {
        positional.append(args[i])
        i += 1
    }
}
guard let first = positional.first, let safe = Address(hex: first.lowercased()) else {
    print("用法：sts-probe [--chain sep] <safe 地址>")
    exit(1)
}

let key = SafeAPIKey.resolve()
let client = STSClient(chain: chain, apiKey: key)
print("STS \(client.baseURL.absoluteString)，API key：\(key == nil ? "无（限 2 RPS / 每月 5,000 次）" : "有")")

do {
    let about = try await client.about()
    print("服务：\(about.name) \(about.version)")

    let info = try await client.safeInfo(safe)
    print("Safe \(info.address) v\(info.version ?? "?")：\(info.threshold)-of-\(info.owners.count)，nonce \(info.nonce)")
    for owner in info.owners { print("  owner \(owner)") }

    let page = try await client.multisigTransactions(safe, limit: 10)
    print("多签交易：共 \(page.count.map(String.init) ?? "?") 笔，取最近 \(page.results.count) 笔")
    var mismatches = 0
    for tx in page.results {
        let local = try tx.safeTx().hash(chainId: UInt256(chain.chainId), safe: safe).hexString
        let ok = local == tx.safeTxHash.lowercased()
        if !ok { mismatches += 1 }
        let sigTypes = (tx.confirmations ?? []).compactMap(\.signatureType)
        print("  nonce \(tx.nonce) \(tx.isExecuted ? "已执行" : "待执行") \(tx.confirmations?.count ?? 0)/\(tx.confirmationsRequired) [\(sigTypes.joined(separator: ","))] safeTxHash \(ok ? "✔ 本地重算一致" : "✘ 本地 \(local) ≠ STS \(tx.safeTxHash)")")
    }
    if let latest = page.results.first {
        let single = try await client.multisigTransaction(safeTxHash: Data(hex: latest.safeTxHash)!)
        print("按哈希查询：nonce \(single.nonce) \(single.safeTxHash == latest.safeTxHash ? "✔" : "✘")")
    }
    exit(mismatches == 0 ? 0 : 2)
} catch STSError.http(let status, let body) {
    print("HTTP \(status)：\(body)")
    exit(1)
} catch {
    print("错误：\(error)")
    exit(1)
}
