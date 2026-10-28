import CoordinatorFlow
import SafeTransactionService
import SwiftUI
import UniPassCore

/// 发送：选资产 → 收款人 → 金额 → 确认 → 签名面板。界面上只有代币单位和名字；
/// 原始字段（to、data、nonce、指纹）只在确认页折叠的"技术细节"里。
struct SendFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    @Environment(\.dismiss) private var dismiss

    enum Step: Int {
        case asset, recipient, amount, confirm, sign
    }

    @State private var step: Step = .asset
    @State private var asset: Asset?
    @State private var recipientText = ""
    @State private var saveToBook = true
    @State private var newName = ""
    @State private var amountText = ""
    @State private var request: SafeTxRequest?
    /// 发给哪一台签名器签。
    @State private var signer: PairedSigner?
    /// 收款人是不是签名合约地址（不能收款）；nil = 还在查。
    @State private var recipientIsSigner: Bool?


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Divider()
            Group {
                switch step {
                case .asset: assetStep
                case .recipient: recipientStep
                case .amount: amountStep
                case .confirm: confirmStep
                case .sign:
                    if let request, let signer {
                        SignPanel(request: request, signer: signer) { dismiss() }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: step == .sign ? 820 : 620, height: step == .sign ? 640 : 600)
        .animation(.default, value: step)
    }

    private var topBar: some View {
        HStack {
            if step != .asset && step != .sign {
                Button { step = Step(rawValue: step.rawValue - 1)! } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help(Text("Back"))
            }
            Text(title).font(.headline)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(Text("Close"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var title: LocalizedStringKey {
        switch step {
        case .asset: "Send: choose an asset"
        case .recipient: "Send: recipient"
        case .amount: "Send: amount"
        case .confirm: "Review and confirm"
        case .sign: "Sign"
        }
    }

    // MARK: 1. 资产

    @ViewBuilder private var assetStep: some View {
        let available = safe.assets.filter { $0.balance.map { !$0.isZero } ?? false }
        VStack(alignment: .leading, spacing: 8) {
            if available.isEmpty {
                if safe.loading {
                    ProgressView()
                } else {
                    Text("This Safe has nothing to send yet. Use Receive to move some assets in first.").foregroundStyle(.secondary)
                }
            }
            ForEach(available) { a in
                Button {
                    asset = a
                    amountText = ""
                    step = .recipient
                } label: {
                    AssetRow(asset: a)
                        .padding(12)
                        .contentShape(Rectangle())
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 2. 收款人

    private var recipientResult: Result<Address, RecipientInput.Problem> {
        RecipientInput.parse(recipientText, safe: safe.address)
    }

    private var recipient: Address? { try? recipientResult.get() }

    @ViewBuilder private var recipientStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Paste an address (0x…)", text: $recipientText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { if recipient != nil { recipientNext() } }
            switch recipientResult {
            case .failure(let problem):
                if let message = Self.message(problem) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            case .success(let address) where recipientIsSigner == true:
                Label("This is a signer's address, not a wallet: it belongs to the signing contract of a Safe signer. Anything sent to it is lost forever, so it can't be a recipient. To pay this person, use their wallet address.",
                      systemImage: "nosign")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                NamedAddress(name: app.name(for: address), address: address)
            case .success(let address):
                Card {
                    NamedAddress(name: app.name(for: address), address: address)
                    if recipientIsSigner == nil {
                        HStack { ProgressView().controlSize(.small); Text("Checking the address…").foregroundStyle(.secondary) }
                    }
                    if app.name(for: address) == nil {
                        Toggle("Save to address book", isOn: $saveToBook)
                        if saveToBook {
                            TextField("Name, e.g. Alice", text: $newName).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            if !app.addressBook.entries.isEmpty {
                Text("Address book").font(.headline).padding(.top, 6)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(app.addressBook.entries) { entry in
                            Button {
                                recipientText = entry.addressHex
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                    Text(verbatim: entry.name)
                                    Spacer()
                                    Text(verbatim: AddressDisplay.short(entry.address)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .contentShape(Rectangle())
                                .background(recipient == entry.address ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Continue", action: recipientNext)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recipient == nil || recipientIsSigner != false || (needsName && newName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .task(id: recipient) {
            recipientIsSigner = nil
            guard let recipient else { return }
            recipientIsSigner = await app.checkSignerContract(recipient, chainID: safe.chainID)
        }
    }

    private var needsName: Bool {
        recipient.map { app.name(for: $0) == nil } == true && saveToBook
    }

    private func recipientNext() {
        guard let recipient, recipientIsSigner == false else { return }
        if needsName { app.addressBook.save(name: newName, address: recipient) }
        step = .amount
    }

    static func message(_ p: RecipientInput.Problem) -> String? {
        switch p {
        case .empty: nil
        case .notAnAddress: L("This isn't an Ethereum address. It should be 0x followed by 40 letters and digits.")
        case .badChecksum: L("This address has a typo: its capital letters don't match its checksum. Copy it again from the source.")
        case .zeroAddress: L("This is the zero address. Anything sent to it is lost.")
        case .isTheSafe: L("This is the Safe itself.")
        }
    }

    // MARK: 3. 金额

    private var amountResult: Result<UInt256, AmountInput.Problem>? {
        asset.map { AmountInput.validate(amountText, asset: $0) }
    }

    @ViewBuilder private var amountStep: some View {
        if let asset, let recipient {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("To").foregroundStyle(.secondary)
                    Text(verbatim: app.name(for: recipient) ?? AddressDisplay.short(recipient)).font(.headline)
                }
                HStack(alignment: .firstTextBaseline) {
                    TextField(text: $amountText, prompt: Text(verbatim: "0")) { Text("Amount") }
                        .textFieldStyle(.plain)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .onSubmit { if case .success = amountResult { amountNext() } }
                    Text(verbatim: asset.symbol).font(.title).foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    if let balance = asset.balance {
                        Text("Available: \(asset.display(balance))").foregroundStyle(.secondary)
                        Button("Max") { amountText = AmountInput.plain(balance, decimals: asset.decimals) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                if case .failure(let problem)? = amountResult, let message = Self.message(problem, asset: asset) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Next", action: amountNext)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled({ if case .success? = amountResult { false } else { true } }())
                }
            }
        }
    }

    private func amountNext() {
        guard let asset, let recipient, case .success(let amount)? = amountResult, let nonce = safe.nextNonce else { return }
        request = SafeTxRequest(chainID: safe.chainID, safe: safe.address,
                                tx: Transfer.safeTx(asset: asset, to: recipient, amount: amount, nonce: nonce))
        step = .confirm
    }

    static func message(_ p: AmountInput.Problem, asset: Asset) -> String? {
        switch p {
        case .empty: nil
        case .invalidFormat: L("Enter a number, like 25 or 0.5.")
        case .tooManyDecimals(let max): L("\(asset.symbol) has at most \(max) decimal places.")
        case .zero: L("The amount must be more than 0.")
        case .tooLarge: L("The amount is too large.")
        case .insufficientBalance: L("Not enough \(asset.symbol) in the Safe.")
        }
    }

    // MARK: 4. 确认

    @ViewBuilder private var confirmStep: some View {
        if let request, let recipient, let asset, case .success(let amount)? = amountResult {
            VStack(spacing: 0) {
                // 一句话摘要固定在顶部，不随下面的内容滚走。
                HStack(spacing: 12) {
                    AssetIcon(symbol: asset.symbol, size: 40)
                    Text(verbatim: app.summary(request).sentence).font(.title2.bold())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Card {
                            LabeledContent("Amount") { Text(verbatim: asset.display(amount)).font(.headline) }
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("To").foregroundStyle(.secondary)
                                NamedAddress(name: app.name(for: recipient), address: recipient)
                            }
                            Divider()
                            LabeledContent("From") { Text(verbatim: safe.name) }
                            LabeledContent("Network") { NetworkBadge(chainID: safe.chainID) }
                            LabeledContent("Approvals needed") {
                                Text("\(safe.thresholdValue) of \(safe.ownerList.count) signers")
                            }
                            LabeledContent("Estimated network fee") {
                                if let fee = safe.estimatedFee(request.tx) {
                                    if let rounded = FeeEstimate.rounded(fee, asset: safe.nativeAsset) {
                                        Text("About \(safe.nativeAsset.display(rounded))")
                                    } else {
                                        Text("Less than \(FeeEstimate.smallest(safe.nativeAsset))")
                                    }
                                } else {
                                    Text(verbatim: "—")
                                }
                            }
                            Text("Paid by whoever executes the transaction, not from the Safe.").font(.caption).foregroundStyle(.secondary)
                        }
                        TechnicalDetails(request: request)
                    }
                }
                HStack {
                    Spacer()
                    let signers = app.signers(for: safe)
                    if signers.isEmpty {
                        Text("None of the signers paired with this Mac is a signer of this Safe.").foregroundStyle(.secondary)
                    } else {
                        SignWithButtons(signers: signers) {
                            signer = $0
                            step = .sign
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }
}
