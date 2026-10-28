import AppKit
import CoordinatorFlow
import SafeTransactionService
import SwiftUI
import UniPassCore

/// 签满之后的"执行"：把 `execTransaction` 发到链上。谁发都行，网络费由发送的账户付，Safe 里的钱不动。
///
/// 默认用提交账户执行（`SubmitterAccountUI.swift`）；也可以在 Safe{Wallet} 里用浏览器钱包执行。
struct ExecuteActions: View {
    @Environment(AppModel.self) private var app
    let request: SafeTxRequest
    let tx: MultisigTransaction

    #if DEBUG
    @State private var preflight: Result<Void, Error>?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All signatures are in. Execute the transaction to put it on chain.", systemImage: "checkmark.seal")
                .font(.headline)
            if let signatures = try? SafeSignatures.encode(tx.ownerSignatures()) {
                SubmitterExecuteButton(request: request, signatures: signatures)
            }
            if let url = Display.safeWalletTx(safe: request.safe, safeTxHash: request.safeTxHash, chainID: request.chainID) {
                DisclosureGroup("Other ways to execute") {
                    VStack(alignment: .leading, spacing: 6) {
                        Link(destination: url) {
                            Label("Execute in Safe{Wallet}", systemImage: "arrow.up.forward.app")
                        }
                        Text("Safe{Wallet} opens in your browser. Execute there with any wallet that has a little ETH for the network fee. The funds in the Safe don't pay the fee.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
            #if DEBUG
            if app.developerMode { debugExecution }
            #endif
        }
    }

    #if DEBUG
    /// 测试网：用 Foundry 的一次性账户执行（docs/demo.md）。
    @ViewBuilder private var debugExecution: some View {
        if let signatures = try? SafeSignatures.encode(tx.ownerSignatures()) {
            DisclosureGroup("Testnet execution (debug)") {
                HStack {
                    Button("Preflight checkSignatures") { Task { await runPreflight(signatures) } }
                    switch preflight {
                    case .success?: CheckRow(Text("Passed"), ok: true)
                    case .failure(let e)?: CheckRow(Text("Failed: \(e.localizedDescription)"), ok: false)
                    case nil: EmptyView()
                    }
                }
                let command = ExecTransaction.castCommand(
                    safe: request.safe, tx: request.tx, signatures: signatures,
                    rpcURL: app.rpc(chainID: request.chainID)?.url.absoluteString ?? "<rpc>", account: "<keystore-account>")
                HStack(alignment: .top) {
                    Text(verbatim: command).font(.system(.caption2, design: .monospaced)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    CopyButton(text: command)
                }
            }
            .font(.caption)
        }
    }

    private func runPreflight(_ signatures: Data) async {
        guard let rpc = app.rpc(chainID: request.chainID) else { return }
        do {
            _ = try await rpc.call(to: request.safe, data: ExecTransaction.checkSignaturesCalldata(request, signatures: signatures))
            preflight = .success(())
        } catch {
            preflight = .failure(error)
        }
    }
    #endif
}
