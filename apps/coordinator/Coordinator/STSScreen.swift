import SafeTransactionService
import SwiftUI
import UniPassCore

@Observable
final class STSModel {
    var chain = SafeChain.sepolia
    var safeAddress = ""
    var hasStoredKey = SafeAPIKey.resolve() != nil
    var busy = false
    var error: String?
    var about: STSAbout?
    var info: SafeInfo?
    var transactions: [MultisigTransaction] = []
    /// safeTxHash → 本地用 core 重算是否一致。
    var hashChecks: [String: Bool] = [:]

    func load() async {
        guard let safe = Address(hex: safeAddress.trimmingCharacters(in: .whitespaces).lowercased()) else {
            error = L("Not a valid Safe address")
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        let client = STSClient(chain: chain, apiKey: SafeAPIKey.resolve())
        do {
            about = try await client.about()
            info = try await client.safeInfo(safe)
            transactions = try await client.multisigTransactions(safe, limit: 20).results
            hashChecks = [:]
            for tx in transactions {
                let local = try? tx.safeTx().hash(chainId: UInt256(chain.chainId), safe: safe).hexString
                hashChecks[tx.safeTxHash] = local == tx.safeTxHash.lowercased()
            }
        } catch let STSError.http(status, body) {
            error = "HTTP \(status): \(body)"
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// 调试：只读查看交易服务里的 Safe 和交易，并用 core 重算 safeTxHash 对拍。API key 在设置里（⌘,）。
struct STSScreen: View {
    @State private var model = STSModel()

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Chain", selection: $model.chain) {
                    ForEach(SafeChain.known, id: \.self) { Text(verbatim: "\($0.shortName) (\($0.chainId))").tag($0) }
                }
                Text(model.hasStoredKey ? "Using the API key from Settings." : "No API key: limited to 2 requests per second and 5,000 per month. Add one in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Safe address", text: $model.safeAddress)
                        .font(.system(.body, design: .monospaced))
                    Button("Load") { Task { await model.load() } }
                        .disabled(model.busy)
                }
            }
            if let error = model.error {
                Section("Error") { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let about = model.about {
                Section("Service") { LabeledContent(about.name, value: about.version) }
            }
            if let info = model.info {
                Section("Safe") {
                    LabeledContent("Version", value: info.version ?? "?")
                    LabeledContent("Threshold", value: "\(info.threshold) / \(info.owners.count)")
                    LabeledContent("nonce", value: info.nonce.description)
                    ForEach(info.owners, id: \.self) { HexField(label: "owner", value: $0) }
                }
            }
            if !model.transactions.isEmpty {
                Section("Multisig transactions (latest \(model.transactions.count))") {
                    ForEach(model.transactions, id: \.safeTxHash) { tx in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: "nonce \(tx.nonce.description)").bold()
                                Text(tx.isExecuted ? "Executed" : "Pending").foregroundStyle(tx.isExecuted ? Color.secondary : Color.orange)
                                Text(verbatim: "\(tx.confirmations?.count ?? 0)/\(tx.confirmationsRequired)")
                                Text(verbatim: (tx.confirmations ?? []).compactMap(\.signatureType).joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(verbatim: model.hashChecks[tx.safeTxHash] == true ? "safeTxHash ✔" : "safeTxHash ✘")
                                    .foregroundStyle(model.hashChecks[tx.safeTxHash] == true ? .green : .red)
                            }
                            Text(verbatim: tx.safeTxHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transaction Service (STS)")
    }
}
