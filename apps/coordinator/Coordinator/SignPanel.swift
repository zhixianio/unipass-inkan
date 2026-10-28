import CoordinatorFlow
import SafeTransactionService
import SwiftUI
import UniPassCore

/// 签名面板：签名器签名 → 收回签名 → 提交 → 上链，每一步显示状态。
///
/// 请求发给 `signer` 这一台。这台签完、还差签名时，Safe 里其他还没签的已配对签名器各有一个按钮，接着让它签。
///
/// 显示二维码时摄像头自动打开，签名码一收齐就校验；校验通过后自动保存到 Safe 的交易服务，
/// 其他签名人（包括 Safe{Wallet} 里的）能看到这笔交易。签满后执行。
struct SignPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    /// 用户确认过的那笔交易。
    let request: SafeTxRequest
    var onClose: () -> Void
    /// 这次请求发给的签名器。
    @State private var signer: PairedSigner

    init(request: SafeTxRequest, signer: PairedSigner, onClose: @escaping () -> Void) {
        self.request = request
        _signer = State(initialValue: signer)
        self.onClose = onClose
    }

    enum Step: Int, CaseIterable {
        case sign, receive, submit, execute

        var title: LocalizedStringKey {
            switch self {
            case .sign: "Signer signs"
            case .receive: "Get signature"
            case .submit: "Submit"
            case .execute: "On chain"
            }
        }
    }

    enum SubmitState: Equatable {
        case idle, working, done, failed(String)
        #if DEBUG
        case skippedForDemo
        #endif
    }

    @State private var session: SignRequestSession?
    @State private var scan = ScanModel(acceptedTypes: [SignerSignature.urType])
    @State private var check: SignatureCheck?
    @State private var receiveError = false
    /// 收回的签名其实是另一台已配对签名器签的（拿错了手机）。
    @State private var wrongSigner: PairedSigner?
    @State private var submit: SubmitState = .idle
    @State private var serviceTx: MultisigTransaction?

    private var current: Step {
        if check?.passed != true { return session == nil || scan.tracker.progress == 0 && check == nil ? .sign : .receive }
        if submit != .done { return .submit }
        return .execute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: app.summary(request).sentence).font(.title2.bold())
                HStack(spacing: 8) {
                    Text(verbatim: safe.name).foregroundStyle(.secondary)
                    NetworkBadge(chainID: request.chainID)
                    Label { Text(verbatim: signer.name) } icon: { Image(systemName: "iphone") }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            stepper
            Divider()
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: start)
        .onDisappear { scan.stop() }
        .task(id: pollKey) { await poll() }
    }

    // MARK: 步骤条

    private var stepper: some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases, id: \.self) { step in
                HStack(spacing: 6) {
                    stepIcon(step)
                    Text(step.title).font(.callout.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                }
                if step != .execute {
                    Rectangle().fill(step.rawValue < current.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2).frame(maxWidth: .infinity).padding(.horizontal, 8)
                }
            }
        }
    }

    @ViewBuilder private func stepIcon(_ step: Step) -> some View {
        let failed = (step == .receive && (check?.passed == false || receiveError))
            || (step == .submit && { if case .failed = submit { true } else { false } }())
        if failed {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if step.rawValue < current.rawValue || (step == .execute && isExecuted) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if step == current {
            Image(systemName: "\(step.rawValue + 1).circle.fill").foregroundStyle(.tint)
        } else {
            Image(systemName: "\(step.rawValue + 1).circle").foregroundStyle(.secondary)
        }
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        switch current {
        case .sign, .receive: signContent
        case .submit: submitContent
        case .execute: executeContent
        }
    }

    @ViewBuilder private var signContent: some View {
        if let session {
            HStack(alignment: .top, spacing: 20) {
                AnimatedURView(ur: session.ur).frame(width: 300)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan this code with UniPass Inkan Signer on “\(signer.name)”, check the details on the signer and confirm with Face ID, then hold the code on the signer up to this Mac's camera.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    URScannerView(model: scan, prompt: "Waiting for the code on the signer…")
                        .frame(maxWidth: 320)
                    if let check, !check.passed {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(SignatureCheck.Item.allCases, id: \.self) { item in
                                CheckRow(Text(item.title), ok: check.results[item])
                            }
                            if let wrongSigner {
                                Text("This signature is from “\(wrongSigner.name)”, but the request was sent to “\(signer.name)”. It won't be used.").foregroundStyle(.red)
                            } else {
                                Text("This signature doesn't match the transaction and won't be used.").foregroundStyle(.red)
                            }
                            Button("Scan Again") { restartReceive() }
                        }
                    } else if receiveError {
                        Text("That code couldn't be read. Show the signature code on the signer again.").foregroundStyle(.red)
                    }
                    LabeledContent("Fingerprint") {
                        Text(verbatim: HashDisplay.short(request.safeTxHash)).font(.system(.callout, design: .monospaced))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var submitContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            CheckRow(Text("Signature received and checked"), ok: true)
            switch submit {
            case .idle, .working:
                HStack { ProgressView().controlSize(.small); Text("Saving the signature so the other signers can see it…") }
            case .failed(let message):
                Text(verbatim: message).foregroundStyle(.red).textSelection(.enabled)
                Button("Try Again") { Task { await save() } }
            case .done:
                EmptyView()
            #if DEBUG
            case .skippedForDemo:
                Text("Demo: the signature was not saved.", tableName: "AttackDemo").foregroundStyle(.secondary)
                Button("Close", action: onClose)
            #endif
            }
        }
    }

    @ViewBuilder private var executeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tx = serviceTx {
                let status = safe.status(of: tx)
                SignerList(tx: tx)
                switch status {
                case .awaitingSignatures(let collected, let required):
                    let next = app.signers(for: safe).filter { !tx.hasConfirmation(from: $0.signerProxy) }
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(required - collected) more signatures. Other signers can approve this transaction in Safe{Wallet} or with their own signer.")
                    }
                    .foregroundStyle(.secondary)
                    if !next.isEmpty {
                        SignWithButtons(signers: next) { ask($0) }
                    }
                case .ready:
                    ExecuteActions(request: request, tx: tx)
                case .executed(let ok):
                    if let hash = tx.transactionHash {
                        Label(ok ? L("Done. The transaction is on chain.") : L("The transaction was executed but failed."),
                              systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(ok ? .green : .red)
                            .font(.headline)
                        if let url = Display.explorerTx(hash, chainID: request.chainID) {
                            Link("View on block explorer", destination: url)
                        }
                    }
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                case .confirming:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("The transaction is on chain. Waiting for Safe's transaction service to record it…")
                    }
                    .foregroundStyle(.secondary)
                case .unconfirmed:
                    UnconfirmedNotice()
                case .replaced:
                    Text("Another transaction with the same number was executed first, so this one can no longer run.").foregroundStyle(.orange)
                }
            } else {
                ProgressView()
            }
        }
    }

    private var isExecuted: Bool { serviceTx?.isExecuted == true }

    // MARK: 动作

    private func start() {
        guard session == nil else { return }
        var sent = request
        #if DEBUG
        if let scenario = app.attackDemo.scenario {
            sent = scenario.tamper(request)
            app.attackDemo.record(scenario, shown: request, sent: sent)
        } else {
            app.attackDemo.lastSent = nil
        }
        #endif
        session = SignRequestSession(request: sent, signer: signer, registration: safe.registration)
        scan.onResult = { received($0) }
        restartReceive()
    }

    /// 换一台签名器接着签：重新出二维码，发给它。
    private func ask(_ next: PairedSigner) {
        scan.stop()
        signer = next
        session = nil
        submit = .idle
        start()
    }

    private func restartReceive() {
        check = nil
        wrongSigner = nil
        receiveError = false
        scan.reset()
        Task { await scan.start() }
    }

    private func received(_ ur: UR) {
        guard let session else { return }
        do {
            let signature = try SignerSignature(ur: ur)
            let c = SignatureCheck(signature, for: session)
            check = c
            wrongSigner = c.passed ? nil : SignatureCheck.signedBy(signature, for: session, among: app.signers.all)
            receiveError = false
            if c.passed { Task { await save() } }
        } catch {
            receiveError = true
            restartReceive()
        }
    }

    private func save() async {
        guard let session, let owner = check?.ownerSignature else { return }
        #if DEBUG
        if app.attackDemo.lastSent != nil {
            submit = .skippedForDemo
            return
        }
        #endif
        guard let service = app.sts(chainID: request.chainID) else { return }
        submit = .working
        do {
            _ = try await service.submit(owner, safe: session.request.safe, transaction: session.request.tx, origin: SignRequestSession.origin)
            serviceTx = try? await service.multisigTransaction(safeTxHash: session.safeTxHash)
            submit = .done
            await app.refresh()
            if let serviceTx { safe.update(serviceTx) }
        } catch let STSError.http(status, body) {
            submit = .failed(F("Could not save the signature (%lld): %@", Int64(status), body))
        } catch {
            submit = .failed(L("Could not save the signature. Check the network and try again."))
        }
    }

    private var pollKey: String { "\(current.rawValue)-\(isExecuted)" }

    /// 等其他签名、等上链：每 5 秒问一次交易服务。
    private func poll() async {
        guard current == .execute, !isExecuted, let service = app.sts(chainID: request.chainID) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if let tx = try? await service.multisigTransaction(safeTxHash: request.safeTxHash) {
                serviceTx = tx
                safe.update(tx)
                if tx.isExecuted {
                    await app.refresh()
                    return
                }
            }
        }
    }
}

/// 每个签名人签了没有。
struct SignerList: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe
    let tx: MultisigTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signatures \(tx.confirmations?.count ?? 0) of \(tx.confirmationsRequired)").font(.headline)
            ForEach(safe.ownerList, id: \.self) { owner in
                let signed = tx.hasConfirmation(from: owner)
                HStack {
                    Image(systemName: signed ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(signed ? .green : .secondary)
                    if let name = app.name(for: owner) {
                        Text(verbatim: name)
                    } else {
                        Text("Unnamed signer").foregroundStyle(.secondary)
                    }
                    if app.signers.contains(owner) {
                        Image(systemName: "iphone").foregroundStyle(.secondary).help(Text("Paired with this Mac"))
                    }
                    Text(verbatim: AddressDisplay.short(owner)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(signed ? "Signed" : "Waiting").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 让某一台已配对的签名器签名：每台一个按钮，第一个是默认按钮。只剩一台时就只有它。
struct SignWithButtons: View {
    let signers: [PairedSigner]
    var action: (PairedSigner) -> Void

    var body: some View {
        HStack {
            ForEach(Array(signers.enumerated()), id: \.element.signerProxy) { i, s in
                if i == 0 {
                    button(s).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    button(s)
                }
            }
        }
    }

    private func button(_ s: PairedSigner) -> some View {
        Button { action(s) } label: { Label("Sign with \(s.name)", systemImage: "iphone") }
    }
}
