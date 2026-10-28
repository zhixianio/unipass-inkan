import CoordinatorFlow
import SafeTransactionService
import SubmitterAccount
import SwiftUI
import UniPassCore

// 提交账户的界面：设置里的"提交账户"页和签满后的"执行"按钮。
// 账户逻辑都在 Packages/SubmitterAccount；去掉这个功能时删掉这个文件、那个包，以及 AppModel / ExecuteActions / SettingsScreen 里引用它的几行。

@Observable
final class SubmitterModel {
    /// 钥匙串里的私钥（白名单在 `account` 里按当前的 Safe 列表配上）。
    private var stored: SubmitterAccount?
    /// 允许执行的 Safe：这台 Mac 上列表里的全部 Safe，按 (链, 地址)（AppModel 在列表变化时更新）。
    var safes: Set<SigningPolicy.RegisteredSafe> = []

    /// 带着当前白名单的提交账户。
    var account: SubmitterAccount? { stored?.with(policy: SigningPolicy(safes: safes)) }
    var loadError: String?
    var balance: UInt256?
    /// 当前网络下执行一笔 Safe 交易最多要付的网络费（估算，用来判断余额够不够）。
    var executionCost: UInt256?

    /// 第一次用到时生成私钥存进钥匙串。
    func load() {
        guard stored == nil else { return }
        do {
            stored = try SubmitterAccount.loadOrCreate(policy: SigningPolicy(safes: safes))
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    func refresh(rpc: EthRPC?) async {
        load()
        guard let account, let rpc else { return }
        balance = try? await rpc.balance(of: account.address)
        if let base = try? await rpc.baseFee(), let tip = try? await rpc.maxPriorityFeePerGas() {
            executionCost = FeeEstimate.fee(gas: Self.executionGasCeiling, baseFee: base.adding(base) ?? base, tip: tip)
        }
    }

    /// 估算执行一笔交易时按这个 gas 留余量（实测 2-of-2 约 93k，留足）。
    static let executionGasCeiling: UInt64 = 300_000

    /// 余额够不够再执行几笔。
    var isLow: Bool {
        guard let balance else { return false }
        guard let cost = executionCost, !cost.isZero else { return balance.isZero }
        return balance < (FeeEstimate.fee(gas: 3, baseFee: cost, tip: .zero) ?? cost)
    }

    func replace() {
        do {
            stored = try SubmitterAccount.replace(policy: SigningPolicy(safes: safes))
            balance = nil
        } catch {
            loadError = String(describing: error)
        }
    }
}

private extension UInt256 {
    func adding(_ rhs: UInt256) -> UInt256? {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (a, o1) = words[i].addingReportingOverflow(rhs.words[i])
            let (b, o2) = a.addingReportingOverflow(carry)
            out[i] = b
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return carry == 0 ? UInt256(words: out) : nil
    }
}

extension SubmitterAccount.SubmitError {
    @MainActor var message: String {
        switch self {
        case .insufficientBalance: L("The submitter account doesn't have enough ETH for the network fee. Top it up in Settings › Submitter Account.")
        case .nothingToSweep: L("The balance is too small to cover the network fee of a transfer.")
        case .overflow: L("The network fee looks wrong. Try again later.")
        case .wrongChain(let expected, _):
            F("The blockchain node isn't on %@, so nothing was signed. Check the node in Settings › Advanced.", Display.network(expected))
        case .costAboveEstimate:
            L("The blockchain node asked for a much higher network fee than this transaction should need, so nothing was signed. Try again later, or set a different node in Settings › Advanced.")
        }
    }
}

extension SigningPolicy.Violation {
    @MainActor var message: String {
        switch self {
        case .notAllowed: L("The submitter account only executes transactions for Safes registered in this app.")
        case .wrongChain: L("The submitter account only signs on Ethereum, Base and Sepolia.")
        case .gasLimitTooHigh, .feeTooHigh:
            L("The network fee is above the submitter account's limit, so nothing was signed. Try again later, or set a different node in Settings › Advanced.")
        }
    }
}

/// 报价里的网络费：大约多少、最多多少（最多 = gasLimit × maxFee，余额至少要有这么多才发得出去）。执行、创建 Safe、转出余额之前都显示。
struct NetworkFeeRows: View {
    let quote: SubmitterAccount.Quote
    let asset: Asset

    var body: some View {
        LabeledContent("Estimated network fee") { Text(verbatim: Self.text(quote.expectedFee, asset: asset, about: true)) }
        LabeledContent("Network fee at most") {
            Text(verbatim: Self.text(quote.transaction.maxFeePerGas.times(quote.transaction.gasLimit), asset: asset, about: false))
        }
    }

    @MainActor static func text(_ fee: UInt256, asset: Asset, about: Bool) -> String {
        guard let rounded = FeeEstimate.rounded(fee, asset: asset) else { return F("Less than %@", FeeEstimate.smallest(asset)) }
        return about ? F("About %@", asset.display(rounded)) : asset.display(rounded)
    }
}

extension UInt256 {
    /// 每 gas 价格 × gas（价格在白名单上限以内，不会溢出）。
    func times(_ gas: UInt64) -> UInt256 {
        let (high, low) = gas.multipliedFullWidth(by: words[0])
        return UInt256(words: [low, high, 0, 0])
    }
}

// MARK: 设置页

struct SubmitterAccountSettings: View {
    @Environment(AppModel.self) private var app
    @State private var sweeping = false
    @State private var confirmReplace = false

    private var model: SubmitterModel { app.submitter }
    private var native: Asset { Asset.native(chainID: app.chainID) }

    var body: some View {
        Form {
            Section {
                Text("A small wallet on this Mac that puts fully signed transactions on chain and pays their network fee. It is not a signer of your Safe and can't move anything in it. Keep only a little ETH here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let account = model.account {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        AddressQRCode(address: account.address, size: 140)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                AddressText(address: account.address, font: .system(.callout, design: .monospaced))
                                CopyButton(text: account.address.checksummed)
                            }
                            LabeledContent("Network") { NetworkBadge(chainID: app.chainID) }
                            LabeledContent("Balance") {
                                if let balance = model.balance {
                                    Text(verbatim: native.display(balance, fractionDigits: 6))
                                        .help(Text(verbatim: native.display(balance)))
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                    }
                    if model.isLow {
                        Label("Top up the submitter account with a little ETH: send it to the address above on \(Display.network(app.chainID)).",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Submitter account")
                }
                Section {
                    Button("Withdraw Balance…") { sweeping = true }
                        .disabled(model.balance?.isZero ?? true)
                } footer: {
                    Text("Sends everything in this account, minus the network fee, to an address you choose.")
                }
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Replace the submitter account")
                            Text("Deletes this account's key from this Mac and creates a new one.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use a New Account…", role: .destructive) { confirmReplace = true }
                    }
                } header: {
                    Text("Danger zone")
                } footer: {
                    Text("There is no backup and no key export: if this Mac is lost, only the gas money in this account is lost. Withdraw the balance before switching to a new account.")
                }
            } else if let error = model.loadError {
                Text("Could not open the submitter account: \(error)").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task {
            // 打开时刷新，开着的时候每 15 秒再刷新一次（充值到账能自己看到）。
            while !Task.isCancelled {
                await model.refresh(rpc: app.rpc(chainID: app.chainID))
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $sweeping) { SweepSheet() }
        .confirmationDialog("Use a new submitter account?", isPresented: $confirmReplace) {
            Button("Use a New Account", role: .destructive) {
                model.replace()
                Task { await model.refresh(rpc: app.rpc(chainID: app.chainID)) }
            }
        } message: {
            if let balance = model.balance, !balance.isZero {
                Text("The current account still holds \(native.display(balance, fractionDigits: 6)). Its key will be deleted and that balance can't be recovered. Withdraw it first.")
            } else {
                Text("The current account's key will be deleted from this Mac.")
            }
        }
    }
}

/// 转出余额：地址做 EIP-55 校验，确认时再显示一遍金额和完整地址。
struct SweepSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var quote: SubmitterAccount.Quote?
    @State private var confirming = false
    @State private var working = false
    @State private var result: Result<String, Error>?

    private var native: Asset { Asset.native(chainID: app.chainID) }
    private var parsed: Result<Address, RecipientInput.Problem> { RecipientInput.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Withdraw Balance").font(.title2.bold())
            Text("Sends everything in the submitter account, minus the network fee, to an address you choose.")
                .foregroundStyle(.secondary)
            TextField("Paste an address (0x…)", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if case .failure(let p) = parsed, let message = SendFlow.message(p) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if case .success(let a) = parsed {
                NamedAddress(name: app.name(for: a), address: a)
            }
            switch result {
            case .success(let hash)?:
                Label("Sent.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let url = Display.explorerTx(hash, chainID: app.chainID) { Link("View on block explorer", destination: url) }
            case .failure(let e)?:
                Text(verbatim: (e as? SubmitterAccount.SubmitError)?.message ?? (e as? SigningPolicy.Violation)?.message ?? String(describing: e))
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                Button("Continue") { Task { await prepare() } }
                    .buttonStyle(.borderedProminent)
                    .disabled({ if case .success = parsed { false } else { true } }() || working || result != nil)
            }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog("Withdraw the balance?", isPresented: $confirming, presenting: quote) { q in
            Button("Send \(native.display(q.transaction.value))") { Task { await send(q) } }
        } message: { q in
            Text("Send \(native.display(q.transaction.value)) to \(q.transaction.to.checksummed)? Check the whole address. The network fee is at most \(NetworkFeeRows.text(q.transaction.maxFeePerGas.times(q.transaction.gasLimit), asset: native, about: false)).")
        }
    }

    private func prepare() async {
        guard case .success(let to) = parsed, let account = app.submitter.account, let rpc = app.rpc(chainID: app.chainID) else { return }
        working = true
        defer { working = false }
        do {
            quote = try await account.sweepQuote(to: to, chainID: app.chainID, rpc: rpc)
            confirming = true
        } catch {
            result = .failure(error)
        }
    }

    private func send(_ q: SubmitterAccount.Quote) async {
        guard let account = app.submitter.account, let rpc = app.rpc(chainID: app.chainID) else { return }
        working = true
        defer { working = false }
        do {
            result = .success(try await account.send(q, rpc: rpc))
        } catch {
            result = .failure(error)
        }
        await app.submitter.refresh(rpc: rpc)
    }
}

// MARK: 执行

/// 签满后的"执行"：先用提交账户报价，显示网络费（大约、最多），用户确认后才签名发出 `execTransaction`。
struct SubmitterExecuteButton: View {
    @Environment(AppModel.self) private var app
    let request: SafeTxRequest
    let signatures: Data
    @State private var working = false
    @State private var quote: SubmitterAccount.Quote?
    @State private var sent: String?
    @State private var reverted = false
    @State private var error: String?

    private var native: Asset { Asset.native(chainID: request.chainID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sent {
                if reverted {
                    Text("The transaction was reverted on chain. The network fee was still paid.").foregroundStyle(.red)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Sent. Waiting for it to be included in a block…")
                    }
                }
                if let url = Display.explorerTx(sent, chainID: request.chainID) { Link("View on block explorer", destination: url) }
            } else if let quote {
                NetworkFeeRows(quote: quote, asset: native)
                Text("Paid by the submitter account. The fee at most is what it must hold to send; usually much less is used.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { self.quote = nil }
                    Button { Task { await send(quote) } } label: { Label("Send", systemImage: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }
            } else {
                HStack {
                    Button { Task { await prepare() } } label: { Label("Execute", systemImage: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || app.submitter.account == nil)
                    if working { ProgressView().controlSize(.small) }
                }
                if let account = app.submitter.account, let balance = app.submitter.balance {
                    Text("The network fee is paid by the submitter account \(AddressDisplay.short(account.address)) (balance \(native.display(balance, fractionDigits: 6))).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error, sent == nil {
                Text(verbatim: error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Open Settings") }
            }
        }
        .task { await app.submitter.refresh(rpc: app.rpc(chainID: request.chainID)) }
    }

    /// 报价：节点必须在这笔交易的链上，网络费在提交账户的上限以内。
    private func prepare() async {
        guard let account = app.submitter.account, let rpc = app.rpc(chainID: request.chainID) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let calldata = ExecTransaction.calldata(request.tx, signatures: signatures)
            quote = try await account.quote(to: request.safe, data: calldata, chainID: request.chainID, rpc: rpc)
        } catch {
            self.error = Self.message(error)
        }
    }

    private func send(_ q: SubmitterAccount.Quote) async {
        guard let account = app.submitter.account, let rpc = app.rpc(chainID: request.chainID) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let hash = try await account.send(q, rpc: rpc)
            sent = hash
            await app.submitter.refresh(rpc: rpc)
            await confirm(hash, rpc: rpc)
            return
        } catch {
            self.error = Self.message(error)
            quote = nil
        }
        await app.submitter.refresh(rpc: rpc)
    }

    @MainActor static func message(_ error: Error) -> String {
        switch error {
        case let e as SubmitterAccount.SubmitError: e.message
        case let e as SigningPolicy.Violation: e.message
        case EthRPC.RPCError.rpc(_, let message): F("The network rejected the transaction: %@", message)
        default: L("Could not execute. Check the network and try again.")
        }
    }

    /// 等交易进块（最多约 3 分钟），再从交易服务取回这一笔的最新状态写回列表：交易服务通常晚几秒才记上。
    /// 用户中途关掉窗口也会跑完，活动页因此不用手动刷新。
    private func confirm(_ hash: String, rpc: EthRPC) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(3))
            guard let receipt = try? await rpc.receipt(hash) else { continue }
            reverted = !receipt.succeeded
            break
        }
        await app.refresh()
        guard !reverted, let sts = app.sts(chainID: request.chainID) else { return }
        for _ in 0..<10 {
            if let tx = try? await sts.multisigTransaction(safeTxHash: request.safeTxHash) {
                app.safe?.update(tx)
                if tx.isExecuted { return }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
