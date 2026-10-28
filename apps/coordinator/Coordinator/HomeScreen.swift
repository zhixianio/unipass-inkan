import CoordinatorFlow
import SafeTransactionService
import SwiftUI
import UniPassCore

/// 首页：Safe 是谁、有多少钱、谁能签，以及"发送""接收"。
struct HomeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    @Environment(\.openSettings) private var openSettings


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                pendingNotice
                assetsCard
                ownersCard
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Assets")
        .toolbar {
            ToolbarItem {
                Button { Task { await app.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(safe.loading)
            }
        }
        .task { await app.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: safe.name).font(.title2.bold())
                HStack(spacing: 6) {
                    Text(verbatim: AddressDisplay.short(safe.address)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    CopyButton(text: safe.address.checksummed)
                    if let url = Display.explorerAddress(safe.address, chainID: safe.chainID) {
                        Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.borderless)
                            .help(Text("View on Block Explorer"))
                            .accessibilityLabel(Text("View on Block Explorer"))
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                NetworkBadge(chainID: safe.chainID)
                Text("\(safe.thresholdValue)/\(safe.ownerList.count) signatures").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { app.sending = true } label: {
                Label("Send", systemImage: "arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.canSend)
            Button { app.receiving = true } label: {
                Label("Receive", systemImage: "arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    @ViewBuilder private var pendingNotice: some View {
        if app.signers.isEmpty {
            Card {
                Label("No signer paired. UniPass Inkan Signer approves every transaction from this Safe, so pair it before sending.",
                      systemImage: "iphone")
                Button("Pair a Signer…") {
                    SettingsScreen.selectedTab = .safes
                    openSettings()
                }
            }
        } else if app.signers(for: safe).isEmpty {
            Card {
                Label("None of the signers paired with this Mac is a signer of this Safe, so you can't send from it here. Pair one of its signers first.",
                      systemImage: "iphone.slash")
                Button("Pair a Signer…") {
                    SettingsScreen.selectedTab = .safes
                    openSettings()
                }
            }
        }
        let pending = safe.transactions.filter { safe.status(of: $0).isPending }
        if !pending.isEmpty {
            Button { app.page = .activity } label: {
                HStack {
                    Image(systemName: "clock.badge.exclamationmark")
                    Text("\(pending.count) transactions waiting for signatures or execution")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        ConfigurationChangeBanner()
        LoadFailureBanner()
    }

    private var assetsCard: some View {
        let visible = safe.assets.filter { $0.kind == .native || $0.balance.map { !$0.isZero } ?? true }
        let empty = safe.assets.filter { $0.kind != .native && $0.balance?.isZero == true }
        return Card {
            Text("Assets").font(.headline)
            ForEach(visible) { AssetRow(asset: $0) }
            if !empty.isEmpty {
                DisclosureGroup {
                    ForEach(empty) { AssetRow(asset: $0) }
                } label: {
                    Text("\(empty.count) tokens with no balance").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ownersCard: some View {
        Card {
            HStack {
                Text("Signers").font(.headline)
                Spacer()
                Text("Any \(safe.thresholdValue) of \(safe.ownerList.count) must approve").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(safe.ownerList, id: \.self) { owner in
                HStack(alignment: .top, spacing: 10) {
                    let isSigner = app.signers.contains(owner)
                    Image(systemName: isSigner ? "iphone" : "person.crop.circle")
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(isSigner ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let name = app.name(for: owner) {
                                Text(verbatim: name).font(.body.weight(.medium))
                            } else {
                                Text("Unnamed signer").foregroundStyle(.secondary)
                            }
                            if isSigner {
                                Text("Paired with this Mac").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(verbatim: AddressDisplay.short(owner)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // 签名合约地址不给复制：它不能收款，复制出去只会被当成收款地址用。
                    if !app.isSignerContract(owner) { CopyButton(text: owner.checksummed) }
                }
            }
        }
    }
}

struct AssetRow: View {
    let asset: Asset

    var body: some View {
        HStack(spacing: 12) {
            AssetIcon(symbol: asset.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: asset.symbol).font(.body.weight(.medium))
                Text(verbatim: asset.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let balance = asset.balance {
                Text(verbatim: asset.display(balance)).font(.body.monospacedDigit())
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
