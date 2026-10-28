import AppKit
import CoordinatorFlow
import QRTransport
import SafeTransactionService
import SwiftUI
import UniPassCore

// 钱包页面共用的小组件：交易摘要句、状态标签、资产图标、复制按钮、收款码、技术细节。

extension TransactionSummary {
    /// 一句话描述，例如"发送 25 USDC 给 Alice"。
    var sentence: String {
        switch kind {
        case .send(let amount, let to, let name):
            L("Send \(amount) to \(name ?? AddressDisplay.short(to))")
        case .contractCall(let target, let name):
            L("Call contract \(name ?? AddressDisplay.short(target))")
        case .batch(let count):
            L("Batch of \(count) actions")
        case .settingsChange:
            L("Change Safe settings")
        case .empty:
            L("Cancel a pending transaction")
        }
    }

    var symbol: String {
        switch kind {
        case .send: "arrow.up.right"
        case .contractCall: "curlybraces"
        case .batch: "square.stack.3d.up"
        case .settingsChange: "gearshape"
        case .empty: "xmark"
        }
    }
}

extension QueueStatus {
    var title: String {
        switch self {
        case .awaitingSignatures(let collected, let required): L("Signed \(collected)/\(required)")
        case .ready: L("Ready to execute")
        case .executed(true): L("On chain")
        case .executed(false): L("Failed")
        case .confirming: L("Confirming on chain")
        case .unconfirmed: L("Status not confirmed")
        case .replaced: L("Replaced")
        }
    }

    var color: Color {
        switch self {
        case .awaitingSignatures: .orange
        case .ready: .blue
        case .executed(true): .green
        case .executed(false): .red
        case .confirming: .blue
        case .unconfirmed: .orange
        case .replaced: .secondary
        }
    }

    var isPending: Bool {
        switch self {
        case .awaitingSignatures, .ready: true
        case .confirming, .unconfirmed: true
        case .executed, .replaced: false
        }
    }
}

struct StatusBadge: View {
    let status: QueueStatus

    var body: some View {
        Text(verbatim: status.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

/// 代币图标：没有图片资源，用首字母圆标。
struct AssetIcon: View {
    let symbol: String
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(Self.color(symbol).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(verbatim: String(symbol.prefix(1)))
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }

    static func color(_ symbol: String) -> Color {
        switch symbol {
        case "ETH": .indigo
        case "USDC": .blue
        case "EURC": .teal
        case "LINK": .cyan
        default: .gray
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(Text("Copy"))
    }
}

/// 名字（有的话）+ 完整地址（首尾 8 位加粗）。
struct NamedAddress: View {
    let name: String?
    let address: Address

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name {
                Text(verbatim: name).font(.headline)
            } else {
                Text("Not in your address book").font(.subheadline).foregroundStyle(.secondary)
            }
            AddressText(address: address, font: .system(.callout, design: .monospaced))
        }
    }
}

/// 收款：Safe 地址的二维码。
struct ReceiveSheet: View {
    let safe: SafeState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Receive").font(.title2.bold())
            Text("Send only \(Display.network(safe.chainID)) assets to this address.")
                .foregroundStyle(.secondary)
            AddressQRCode(address: safe.address)
            Text(verbatim: safe.name).font(.headline)
            HStack {
                AddressText(address: safe.address)
                CopyButton(text: safe.address.checksummed)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// 地址的二维码（收款用）。
struct AddressQRCode: View {
    let address: Address
    var size: CGFloat = 240

    var body: some View {
        ZStack {
            Color.white
            if let image = QRRenderer.symbol(for: address.checksummed, correction: .medium)?.image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit).padding(size / 15)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 折叠的"技术细节"：只有这里出现 to、data、nonce、safeTxHash 之类的原始字段。
struct TechnicalDetails: View {
    let request: SafeTxRequest

    var body: some View {
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 6) {
                HexField(label: "to", value: request.tx.to.checksummed)
                HexField(label: "value", value: F("%@ wei", request.tx.value.description))
                HexField(label: "data", value: request.tx.data.isEmpty ? "0x" : request.tx.data.hexString)
                HexField(label: "operation", value: request.tx.operation == .call ? "0 (CALL)" : "1 (DELEGATECALL)")
                HexField(label: "Transaction number", value: request.tx.nonce.description)
                if !(request.tx.safeTxGas.isZero && request.tx.baseGas.isZero && request.tx.gasPrice.isZero
                     && request.tx.gasToken == .zero && request.tx.refundReceiver == .zero) {
                    HexField(label: "safeTxGas / baseGas / gasPrice", value: "\(request.tx.safeTxGas) / \(request.tx.baseGas) / \(request.tx.gasPrice)")
                    HexField(label: "gasToken", value: request.tx.gasToken.checksummed)
                    HexField(label: "refundReceiver", value: request.tx.refundReceiver.checksummed)
                }
                HexField(label: "Fingerprint", value: HashDisplay.short(request.safeTxHash))
                HexField(label: "Fingerprint (full)", value: request.safeTxHash.hexString)
            }
            .padding(.top, 4)
        }
    }
}

/// 卡片样式的分组（首页、确认页）。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 刷新（含自动重试）之后还是读不到时的横幅：说清是区块链节点还是 Safe 交易服务。
struct LoadFailureBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe

    var body: some View {
        if let failure = safe.loadFailure {
            HStack {
                Label(Self.text(failure), systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") { Task { await app.refresh() } }.disabled(safe.loading)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    static func text(_ f: SafeState.LoadFailure) -> LocalizedStringKey {
        switch f {
        case .node: "Couldn't reach the blockchain node, so balances and signers may be out of date. Check the network and try again."
        case .service: "Couldn't reach Safe's transaction service, so the transaction list may be out of date. Check the network and try again."
        case .both: "Couldn't reach the blockchain node or Safe's transaction service. Check the network and try again."
        }
    }
}

/// 加进来以后 module、guard、fallback handler 或 singleton 变了：签名器离线核对不了这些，提醒先别批准这个 Safe 的交易。
struct ConfigurationChangeBanner: View {
    @Environment(SafeState.self) private var safe

    var body: some View {
        let changes = ExistingSafe.Field.allCases.filter(safe.configurationChanges.contains)
        if !changes.isEmpty {
            Label {
                Text(verbatim: F("This Safe's settings have changed since it was added: %@. These can let funds move without its signers, or change what a signature approves, and your signer can't check them offline. Don't approve transactions from this Safe until you know who changed them and why.",
                                 changes.map(Self.name).formatted(.list(type: .and))))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
            }
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    static func name(_ f: ExistingSafe.Field) -> String {
        switch f {
        case .modules: L("modules were enabled")
        case .guardAddress: L("a transaction guard was set")
        case .fallbackHandler: L("the fallback handler was replaced")
        case .singleton: L("the implementation contract was replaced")
        case .owners: L("the signers changed")
        case .threshold: L("the threshold changed")
        }
    }
}

/// "状态还没确认"：链上的编号已经过了这一笔，可是两分钟里交易服务都没记上它执行了。
struct UnconfirmedNotice: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This transaction's number has been used on chain, but for two minutes Safe's transaction service hasn't recorded it as executed. Another transaction with the same number may have run instead. Refresh to check again.",
                  systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh") { Task { await app.refresh() } }.disabled(safe.loading)
        }
    }
}
