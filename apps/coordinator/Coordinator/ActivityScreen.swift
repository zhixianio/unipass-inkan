import CoordinatorFlow
import SafeTransactionService
import SwiftUI
import UniPassCore

/// 活动：待处理和已完成的交易（来自 Safe 的交易服务，每一笔都在本地重算哈希核对）。
struct ActivityScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    @State private var selected: MultisigTransaction?


    var body: some View {
        let pending = safe.transactions.filter { safe.status(of: $0).isPending }
        let history = safe.transactions.filter { !safe.status(of: $0).isPending }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ConfigurationChangeBanner()
                LoadFailureBanner()
                if !pending.isEmpty {
                    Text("Pending").font(.headline)
                    ForEach(pending, id: \.safeTxHash) { row($0) }
                }
                if !history.isEmpty {
                    Text("History").font(.headline).padding(.top, pending.isEmpty ? 0 : 12)
                    ForEach(history, id: \.safeTxHash) { row($0) }
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if safe.transactions.isEmpty {
                if safe.loading || safe.lastRefresh == nil {
                    ProgressView("Loading transactions…")
                } else if !safe.loadFailed {
                    ContentUnavailableView {
                        Label("No Transactions Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Transactions you send from this Safe, and ones other signers start, show up here.")
                    } actions: {
                        Button("Send…") { app.sending = true }.disabled(!app.canSend)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button { Task { await app.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(safe.loading)
            }
        }
        .task { await app.refresh() }
        .sheet(item: $selected, onDismiss: { Task { await app.refresh() } }) { TransactionDetail(tx: $0) }
    }

    private func row(_ tx: MultisigTransaction) -> some View {
        Button { selected = tx } label: {
            ActivityRow(tx: tx)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

extension MultisigTransaction: @retroactive Identifiable {
    public var id: String { safeTxHash }
}

struct ActivityRow: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    let tx: MultisigTransaction

    var body: some View {
        let request = safe.request(for: tx)
        let summary = request.map { app.summary($0) }
        HStack(spacing: 12) {
            Image(systemName: summary?.symbol ?? "exclamationmark.triangle")
                .frame(width: 32, height: 32)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                if let summary {
                    Text(verbatim: summary.sentence).font(.body.weight(.medium))
                } else {
                    Text("Transaction that couldn't be verified").foregroundStyle(.red)
                }
                HStack(spacing: 6) {
                    Text(verbatim: "#\(tx.nonce)")
                    if let date = tx.date {
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: safe.status(of: tx))
        }
        .padding(.vertical, 4)
    }
}

/// 一笔交易的详情：是什么、谁签了、现在能做什么。
struct TransactionDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    @Environment(\.dismiss) private var dismiss
    /// 打开时的那份记录；显示用列表里的最新记录（签名、上链之后会变）。
    let opened: MultisigTransaction

    /// 正在让哪一台签名。
    @State private var signing: PairedSigner?

    init(tx: MultisigTransaction) { opened = tx }

    private var tx: MultisigTransaction { safe.transaction(opened.safeTxHash) ?? opened }

    var body: some View {
        let request = safe.request(for: tx)
        let status = safe.status(of: tx)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transaction").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if let signing, let request {
                SignPanel(request: request, signer: signing) { dismiss() }
                    .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let request {
                            details(request, status: status)
                        } else {
                            Label("The transaction service returned data that doesn't match its fingerprint. Don't sign or execute it.",
                                  systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: signing != nil ? 820 : 620, height: signing != nil ? 640 : 600)
    }

    @ViewBuilder private func details(_ request: SafeTxRequest, status: QueueStatus) -> some View {
        let summary = app.summary(request)
        HStack(spacing: 12) {
            Image(systemName: summary.symbol)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: summary.sentence).font(.title2.bold())
                StatusBadge(status: status)
            }
        }
        Card {
            if case .send(let amount, let to, _) = summary.kind {
                LabeledContent("Amount") { Text(verbatim: amount).font(.headline) }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("To").foregroundStyle(.secondary)
                    NamedAddress(name: app.name(for: to), address: to)
                }
                Divider()
            }
            LabeledContent("Network") { NetworkBadge(chainID: request.chainID) }
            if let date = tx.date {
                LabeledContent(tx.isExecuted ? "Executed" : "Created") { Text(date, format: .dateTime) }
            }
        }
        Card { SignerList(tx: tx) }
        actions(request, status: status)
        TechnicalDetails(request: request)
    }

    @ViewBuilder private func actions(_ request: SafeTxRequest, status: QueueStatus) -> some View {
        switch status {
        case .awaitingSignatures:
            // 这个 Safe 里还没签的已配对签名器，每台一个按钮。
            let unsigned = app.signers(for: safe).filter { !tx.hasConfirmation(from: $0.signerProxy) }
            if unsigned.isEmpty {
                Text("Waiting for the other signers.").foregroundStyle(.secondary)
            } else {
                SignWithButtons(signers: unsigned) { signing = $0 }
            }
        case .ready:
            Card { ExecuteActions(request: request, tx: tx) }
        case .executed:
            if let hash = tx.transactionHash, let url = Display.explorerTx(hash, chainID: request.chainID) {
                Link(destination: url) { Label("View on block explorer", systemImage: "arrow.up.forward.square") }
            }
        case .confirming:
            HStack {
                ProgressView().controlSize(.small)
                Text("The transaction is on chain. Waiting for Safe's transaction service to record it…")
            }
            .foregroundStyle(.secondary)
        case .unconfirmed:
            UnconfirmedNotice()
        case .replaced:
            Text("Another transaction with the same number was executed first, so this one can no longer run.").foregroundStyle(.secondary)
        }
    }
}
