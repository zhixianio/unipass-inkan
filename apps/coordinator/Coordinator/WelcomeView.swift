import AppKit
import CoordinatorFlow
import SwiftUI
import UniPassCore

/// 第一次打开时的欢迎引导：这是什么 → 配对签名器 → 给提交账户充值 → 创建或添加 Safe。走完以后不再出现。
/// 充值放在 Safe 之前：创建 Safe 的那笔交易由提交账户发出、付网络费。
struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    enum Step: Int, CaseIterable {
        case intro, pair, fund, safe
    }

    @State private var step: Step = .intro
    @State private var registering = false
    @State private var creating = false
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .animation(.default, value: step)
        .sheet(isPresented: $registering) {
            if let r = app.safe?.registration { SafeRegistrationSheet(registration: r) }
        }
        .sheet(isPresented: $creating) { CreateSafeSheet() }
        .sheet(isPresented: $adding) { AddSafeSheet() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro: intro
        case .pair: pair
        case .safe: safe
        case .fund: fund
        }
    }

    // MARK: 1. 这是什么

    private var intro: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to UniPass Inkan Desktop").font(.largeTitle.bold())
                Text("A desktop wallet for your Safe that works with an offline signer on your iPhone.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                feature("iphone", "Signing happens on your iPhone",
                        "UniPass Inkan Signer stays offline the whole time. Its key never leaves the phone.")
                feature("desktopcomputer", "This Mac prepares and submits",
                        "It builds transactions, shows them as QR codes, collects the signatures and puts the result on chain. It holds no key to your Safe.")
                feature("checkmark.shield", "The signer checks everything itself",
                        "The signer decodes every request and checks it against its own rules, so even a tampered Mac can't trick it.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2. 配对

    @ViewBuilder private var pair: some View {
        header("Pair your signer", "On your iPhone, open UniPass Inkan Signer and tap “Pair with UniPass Inkan Desktop”, then hold the screen up to this Mac's camera.")
        if let paired = app.signers.first {
            Card {
                Label("Paired with “\(paired.name)”", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                LabeledContent("Address in the Safe") { AddressText(address: paired.signerProxy, font: .system(.callout, design: .monospaced)) }
            }
        } else {
            PairSignerView()
            #if DEBUG
            if app.developerMode {
                Button("Simulate Pairing with the Test-Vector Signer") {
                    _ = try? app.pair(PairedSigner(PairSignerView.testVectorPairing, verifiedOnChain: false))
                }
            }
            #endif
        }
    }

    // MARK: 4. Safe

    @ViewBuilder private var safe: some View {
        if let safe = app.safe {
            safeCard(safe)
        } else {
            header("Create or add a Safe", "A Safe holds your funds. Every transaction from it needs approval from enough of its signers, and your iPhone is one of them.")
            HStack(alignment: .top, spacing: 16) {
                choice("plus.square.on.square", "Create a new Safe",
                       "Choose its signers: this iPhone, other UniPass Inkan Signers, hardware or other wallets. The submitter account pays the network fee.",
                       button: "Create a Safe…") { creating = true }
                choice("tray.and.arrow.down", "Add an existing Safe",
                       "For a Safe you already have, if your signer is one of its signers and nothing has changed since it was created.",
                       button: "Add an Existing Safe…") { adding = true }
            }
        }
    }

    private func choice(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, button: LocalizedStringKey,
                        action: @escaping () -> Void) -> some View {
        Card {
            Image(systemName: symbol).font(.title).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func safeCard(_ safe: SafeState) -> some View {
        let r = safe.registration
        header("Your Safe", "Transactions are sent from this Safe. Every one needs approval from enough of its signers.")
        Card {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: safe.name).font(.title3.bold())
                    NetworkBadge(chainID: r.chainID)
                }
                Spacer()
                Text("Any \(Int(clamping: r.threshold)) of \(r.owners.count) must approve").foregroundStyle(.secondary)
            }
            AddressText(address: r.safe, font: .system(.callout, design: .monospaced))
            Divider()
            ForEach(r.owners, id: \.self) { owner in
                let isSigner = app.signers.contains(owner)
                HStack {
                    Image(systemName: isSigner ? "iphone" : "person.crop.circle").frame(width: 22)
                        .foregroundStyle(isSigner ? Color.accentColor : .secondary)
                    if let name = app.name(for: owner) {
                        Text(verbatim: name)
                    } else {
                        Text("Another signer").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: AddressDisplay.short(owner)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        if !app.signers.isEmpty, app.signers(for: safe).isEmpty {
            Label("None of the signers paired with this Mac is an owner of this Safe, so they can't approve its transactions.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        HStack(alignment: .firstTextBaseline) {
            Text("The signer registers this Safe the first time it signs for it. You can also register it now.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Register Now…") { registering = true }
        }
    }

    // MARK: 3. 提交账户充值

    @ViewBuilder private var fund: some View {
        header("Add a little ETH for network fees",
               "This Mac creates your Safe and puts fully signed transactions on chain from its own small submitter account, which pays the network fee. It can't touch the funds in your Safe.")
        if let account = app.submitter.account {
            Card {
                HStack(alignment: .top, spacing: 20) {
                    AddressQRCode(address: account.address, size: 150)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Submitter account").font(.headline)
                        HStack {
                            AddressText(address: account.address, font: .system(.callout, design: .monospaced))
                            CopyButton(text: account.address.checksummed)
                        }
                        NetworkBadge(chainID: app.chainID)
                        LabeledContent("Balance") {
                            if let balance = app.submitter.balance {
                                Text(verbatim: Asset.native(chainID: app.chainID).display(balance, fractionDigits: 6))
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
            Text("A small amount is enough, for example 0.01 ETH on \(Display.network(app.chainID)). It's on the same address on every network. You can top it up or withdraw it any time in Settings.")
                .foregroundStyle(.secondary)
        } else if let error = app.submitter.loadError {
            Label("Could not open the submitter account: \(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    // MARK: 共用

    private func header(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold())
            Text(detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if step != .intro {
                Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            switch step {
            case .intro:
                Button("Get Started") { step = .pair }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .pair:
                Button("Continue") { step = .fund }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.signers.isEmpty)
            case .fund:
                Button("Later") { step = .safe }
                Button("Continue") { step = .safe }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.submitter.balance?.isZero ?? true)
            case .safe:
                if app.safe == nil { Button("Later") { finish() } }
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.safe == nil)
            }
        }
        .controlSize(.large)
        .task(id: step) {
            switch step {
            case .safe:
                await app.refresh()
            case .fund:
                // 充值到账能自己看到。
                while !Task.isCancelled {
                    await app.submitter.refresh(rpc: app.rpc(chainID: app.chainID))
                    try? await Task.sleep(for: .seconds(10))
                }
            default:
                break
            }
        }
    }

    private func finish() {
        app.onboarded = true
        app.page = .home
    }
}
