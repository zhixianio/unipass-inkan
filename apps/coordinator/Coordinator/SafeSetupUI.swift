import CoordinatorFlow
import SafeTransactionService
import SubmitterAccount
import SwiftUI
import UniPassCore

// 创建 Safe、添加已有 Safe。欢迎引导、侧边栏的 Safe 卡片、设置 › 签名器与 Safe 共用。

// MARK: - 创建 Safe

/// 新 Safe 的一个签名人：签名器（有公钥，部署时一起创建它的 proxy）或普通地址（硬件钱包、外部钱包）。
/// 签名器都是这台 Mac 配对过的：扫另一台的配对码时它也进了配对列表，以后签名请求才发得到它。
struct OwnerDraft: Identifiable, Hashable {
    enum Kind: Hashable {
        case signer(x: Data, y: Data, verifiers: Data, factory: Address)
        case address
    }

    let id = UUID()
    var name: String
    var address: Address
    var kind: Kind

    init(paired s: PairedSigner) {
        name = s.name
        address = s.signerProxy
        kind = .signer(x: s.x, y: s.y, verifiers: s.verifiers, factory: s.signerFactory)
    }

    init(name: String, address: Address) {
        self.name = name
        self.address = address
        kind = .address
    }

    var isSigner: Bool {
        if case .signer = kind { true } else { false }
    }
}

@Observable
final class CreateSafeModel {
    enum Phase {
        case form
        case preparing
        case review(Plan)
        case sending
        case waiting(hash: String)
        case done(SafeRegistration, hash: String, gasUsed: UInt64?)
        case failed(String)
    }

    struct Plan {
        let registration: SafeRegistration
        let newSigners: [SafeCreation.NewSigner]
        let quote: SubmitterAccount.Quote
        let balance: UInt256
        var enoughBalance: Bool { !(balance < quote.maxCost) }
    }

    var name = ""
    var chainID: UInt64 = 11_155_111
    var owners: [OwnerDraft] = []
    var threshold = 1
    var phase: Phase = .form

    init(paired: PairedSigner?, chainID: UInt64) {
        if let paired { owners = [OwnerDraft(paired: paired)] }
        self.chainID = chainID
        threshold = SafeCreation.defaultThreshold(owners: max(owners.count, 1))
    }

    func addOwner(_ o: OwnerDraft) -> Bool {
        guard !owners.contains(where: { $0.address == o.address }), owners.count < SafeRegistration.maxOwners else { return false }
        owners.append(o)
        threshold = SafeCreation.defaultThreshold(owners: owners.count)
        return true
    }

    func removeOwner(_ o: OwnerDraft) {
        owners.removeAll { $0.id == o.id }
        threshold = min(max(threshold, 1), max(owners.count, 1))
    }

    var trimmedName: String? {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while n.utf8.count > SafeRegistration.maxNameBytes { n.removeLast() }
        return n.isEmpty ? nil : n
    }

    var canContinue: Bool {
        !owners.isEmpty && (1...owners.count).contains(threshold) && owners.contains(where: \.isSigner)
    }

    /// 准备：核对网络上合约都在、每个签名器的 proxy 地址（链上 `getSigner`）、挑一个没被占用的 saltNonce、估算网络费。
    @MainActor
    func prepare(app: AppModel) async {
        phase = .preparing
        do {
            phase = .review(try await plan(app: app))
        } catch let e as PrepareError {
            phase = .failed(e.message)
        } catch let e as SubmitterAccount.SubmitError {
            phase = .failed(e.message)
        } catch EthRPC.RPCError.rpc(_, let message) {
            phase = .failed(F("The network rejected the transaction: %@", message))
        } catch {
            phase = .failed(L("Could not reach the network. Check the connection and try again."))
        }
    }

    enum PrepareError: Error {
        case missingContracts, signerMismatch(String), noSubmitter, policy(SigningPolicy.Violation)

        @MainActor var message: String {
            switch self {
            case .missingContracts: L("The Safe contracts this app uses are not deployed on this network.")
            case .signerMismatch(let name): F("The address of “%@” does not match its public key on this network. Scan its pairing code again.", name)
            case .noSubmitter: L("The submitter account could not be opened.")
            case .policy(let v): v.message
            }
        }
    }

    @MainActor
    private func plan(app: AppModel) async throws -> Plan {
        guard let rpc = app.rpc(chainID: chainID) else { throw PrepareError.missingContracts }
        for c in SafeCreation.requiredContracts where try await rpc.code(at: c).isEmpty {
            throw PrepareError.missingContracts
        }
        var newSigners: [SafeCreation.NewSigner] = []
        for o in owners {
            guard case .signer(let x, let y, let verifiers, let factory) = o.kind else { continue }
            guard factory == SafeCreation.signerFactory,
                  try await rpc.webAuthnSigner(factory: factory, x: x, y: y, verifiers: verifiers) == o.address else {
                throw PrepareError.signerMismatch(o.name)
            }
            if try await rpc.code(at: o.address).isEmpty {
                newSigners.append(SafeCreation.NewSigner(x: x, y: y, verifiers: verifiers, proxy: o.address))
            }
        }
        var r = SafeCreation.registration(chainID: chainID, owners: owners.map(\.address), threshold: UInt64(threshold),
                                          saltNonce: SafeCreation.randomSaltNonce(), name: trimmedName)
        while try await !rpc.code(at: r.safe).isEmpty {
            r = SafeCreation.registration(chainID: chainID, owners: r.owners, threshold: r.threshold,
                                          saltNonce: SafeCreation.randomSaltNonce(), name: r.name)
        }
        app.submitter.load()
        guard let account = app.submitter.account else { throw PrepareError.noSubmitter }
        let data = SafeCreation.deploymentCalldata(deploying: newSigners, safe: r)
        let quote: SubmitterAccount.Quote
        do {
            quote = try await account.quote(to: SafeCreation.multiSendCallOnly, data: data, chainID: chainID, rpc: rpc)
        } catch let v as SigningPolicy.Violation {
            throw PrepareError.policy(v)
        }
        let balance = try await rpc.balance(of: account.address)
        return Plan(registration: r, newSigners: newSigners, quote: quote, balance: balance)
    }

    /// 发出部署交易，等收据，再核对链上的代码、owner 和阈值，通过后存进 Safe 列表。
    /// 关掉窗口也会跑完（任务不随界面取消），Safe 照样会存进列表。
    @MainActor
    func deploy(_ plan: Plan, app: AppModel) async {
        guard let rpc = app.rpc(chainID: plan.registration.chainID), let account = app.submitter.account else { return }
        phase = .sending
        let hash: String
        do {
            hash = try await account.send(plan.quote, rpc: rpc)
        } catch let e as SubmitterAccount.SubmitError {
            phase = .failed(e.message)
            return
        } catch EthRPC.RPCError.rpc(_, let message) {
            phase = .failed(F("The network rejected the transaction: %@", message))
            return
        } catch {
            phase = .failed(L("Could not send the transaction. Check the network and try again."))
            return
        }
        phase = .waiting(hash: hash)
        var receipt: EthRPC.Receipt?
        for _ in 0..<100 {
            try? await Task.sleep(for: .seconds(3))
            if let r = try? await rpc.receipt(hash) {
                receipt = r
                break
            }
        }
        await app.submitter.refresh(rpc: rpc)
        guard let receipt else {
            phase = .failed(L("The transaction hasn't been included yet. Check it on the block explorer; once it's on chain, add the Safe with Add Existing Safe."))
            return
        }
        guard receipt.succeeded else {
            phase = .failed(L("The transaction failed on chain. The network fee was still paid; nothing was created."))
            return
        }
        let r = plan.registration
        do {
            let code = try await rpc.code(at: r.safe)
            let owners = try await rpc.safeOwners(r.safe)
            let threshold = try await rpc.safeThreshold(r.safe)
            guard !code.isEmpty, owners == r.owners, threshold == UInt256(r.threshold) else {
                phase = .failed(L("The Safe is on chain but doesn't match what was planned. It was not added."))
                return
            }
        } catch {
            phase = .failed(L("The Safe was created, but it couldn't be checked on chain. Add it with Add Existing Safe once the network is back."))
            return
        }
        app.addSafe(r)
        phase = .done(r, hash: hash, gasUsed: receipt.gasUsed.flatMap { UInt256(hex: $0) }.map { $0.words[0] })
    }
}

/// 创建 Safe：填写 → 核对 → 部署 → 完成。
struct CreateSafeView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CreateSafeModel
    var onClose: () -> Void

    @State private var scanningSigner = false
    @State private var addingAddress = false
    @State private var registering = false

    var body: some View {
        Group {
            switch model.phase {
            case .form: form
            case .preparing: progress("Checking the network and estimating the fee…")
            case .review(let plan): review(plan)
            case .sending: progress("Sending…")
            case .waiting(let hash): waiting(hash)
            case .done(let r, let hash, let gas): done(r, hash: hash, gas: gas)
            case .failed(let message): failed(message)
            }
        }
        .sheet(isPresented: $scanningSigner) {
            // 扫到的签名器也配对进这台 Mac，签名请求才发得到它。只交出链上核对过的。
            ScanSignerSheet(chainID: model.chainID) { _ = model.addOwner(OwnerDraft(paired: $0)) }
        }
        .sheet(isPresented: $addingAddress) { AddOwnerAddressSheet(chainID: model.chainID) { _ = model.addOwner($0) } }
    }

    // MARK: 填写

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $model.name, prompt: Text("My Safe"))
                Picker("Network", selection: $model.chainID) {
                    ForEach(SafeCreation.chains, id: \.self) { id in
                        Text(verbatim: Display.network(id) + (Display.isTestnet(id) ? " · " + L("Testnet") : "")).tag(id)
                    }
                }
            } footer: {
                if !Display.isTestnet(model.chainID) {
                    Label("This is a main network: creating the Safe costs real ETH.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(model.owners) { o in ownerRow(o) }
                HStack {
                    let others = app.signers.all.filter { s in !model.owners.contains { $0.address == s.signerProxy } }
                    if others.isEmpty {
                        Button { scanningSigner = true } label: { Label("Add Another Signer…", systemImage: "iphone") }
                    } else {
                        Menu {
                            ForEach(others, id: \.signerProxy) { s in
                                Button(s.name) { _ = model.addOwner(OwnerDraft(paired: s)) }
                            }
                            Divider()
                            Button("Scan Another Signer's Pairing Code…") { scanningSigner = true }
                        } label: {
                            Label("Add Another Signer", systemImage: "iphone")
                        }
                        .fixedSize()
                    }
                    Button { addingAddress = true } label: { Label("Add Address…", systemImage: "person.crop.circle.badge.plus") }
                }
            } header: {
                Text("Signers")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.owners.contains(where: \.isSigner) {
                        if app.signers.isEmpty {
                            Text("Pair your signer first: it has to be one of the signers.").foregroundStyle(.red)
                        } else {
                            Text("Add at least one signer paired with this Mac.").foregroundStyle(.red)
                        }
                    } else {
                        Text("Another UniPass Inkan Signer joins by showing its pairing code. Hardware and other wallets join by address.")
                    }
                }
            }
            Section {
                Stepper(value: $model.threshold, in: 1...max(model.owners.count, 1)) {
                    Text("Any \(model.threshold) of \(model.owners.count) must approve")
                }
                if model.threshold == 1, model.owners.count > 1 {
                    Label("Any one signer alone can move everything in this Safe. Use this only if you mean it.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if model.owners.count == 1 {
                    Label("With a single signer, losing this iPhone means losing access to the Safe. Add a second signer as a backup.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Approvals")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Cancel", action: onClose)
                    Button("Continue") { Task { await model.prepare(app: app) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canContinue)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func ownerRow(_ o: OwnerDraft) -> some View {
        HStack(spacing: 10) {
            Image(systemName: o.isSigner ? "iphone" : "person.crop.circle").frame(width: 22)
                .foregroundStyle(o.isSigner ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: o.name.isEmpty ? AddressDisplay.short(o.address) : o.name)
                    if o.isSigner {
                        Text("Paired with this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                }
                AddressText(address: o.address, font: .system(.caption, design: .monospaced))
            }
            Spacer()
            // 至少留一台签名器。
            if !o.isSigner || model.owners.filter(\.isSigner).count > 1 {
                Button { model.removeOwner(o) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help(Text("Remove"))
            }
        }
    }

    // MARK: 核对

    private func review(_ plan: CreateSafeModel.Plan) -> some View {
        let r = plan.registration
        let native = Asset.native(chainID: r.chainID)
        return Form {
            Section {
                LabeledContent("Name") { Text(verbatim: r.name ?? L("Unnamed")) }
                LabeledContent("Network") { NetworkBadge(chainID: r.chainID) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe address").foregroundStyle(.secondary)
                    AddressText(address: r.safe, font: .system(.callout, design: .monospaced))
                    Text("Computed on this Mac from the creation parameters. The Safe will be at exactly this address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.owners) { o in
                    HStack {
                        Image(systemName: o.isSigner ? "iphone" : "person.crop.circle").frame(width: 22).foregroundStyle(.secondary)
                        Text(verbatim: o.name.isEmpty ? AddressDisplay.short(o.address) : o.name)
                        Spacer()
                        Text(verbatim: AddressDisplay.short(o.address)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Approvals needed") { Text("\(Int(clamping: r.threshold)) of \(r.owners.count) signers") }
                if !plan.newSigners.isEmpty {
                    Text("\(plan.newSigners.count) signer accounts are created on chain in the same transaction.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Signers")
            }
            Section {
                NetworkFeeRows(quote: plan.quote, asset: native)
                LabeledContent("Submitter account balance") { Text(verbatim: native.display(plan.balance, fractionDigits: 6)) }
                if !plan.enoughBalance {
                    Label("The submitter account doesn't have enough ETH on \(Display.network(r.chainID)). Top it up in Settings › Submitter Account, then check again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Paid by this Mac's submitter account, not from the new Safe.")
            }
            Section {
                HStack {
                    Button("Back") { model.phase = .form }
                    Spacer()
                    if !plan.enoughBalance {
                        Button("Check Again") { Task { await model.prepare(app: app) } }
                    }
                    Button("Create Safe") { Task { await model.deploy(plan, app: app) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!plan.enoughBalance)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 进行中、完成、失败

    private func progress(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func waiting(_ hash: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Creating the Safe. Waiting for the transaction to be included in a block…").foregroundStyle(.secondary)
            if let url = Display.explorerTx(hash, chainID: model.chainID) { Link("View on block explorer", destination: url) }
            Text("You can close this window; the Safe is added when the transaction is confirmed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func done(_ r: SafeRegistration, hash: String, gas: UInt64?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Safe created", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green)
                Card {
                    Text(verbatim: r.name ?? AddressDisplay.short(r.safe)).font(.headline)
                    NetworkBadge(chainID: r.chainID)
                    AddressText(address: r.safe, font: .system(.callout, design: .monospaced))
                    if let url = Display.explorerTx(hash, chainID: r.chainID) { Link("View on block explorer", destination: url) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next").font(.headline)
                    Label("Send some assets to the Safe: use Receive on the Assets page.", systemImage: "arrow.down.circle")
                    Label("Register it on your signer: scan the registration code with the signer, or just sign the first transaction, which registers it too.", systemImage: "iphone")
                }
                HStack {
                    Button("Show Registration Code…") { registering = true }
                    Spacer()
                    Button("Done", action: onClose).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $registering) { SafeRegistrationSheet(registration: r) }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text(verbatim: message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close", action: onClose)
                Button("Back to the Form") { model.phase = .form }.buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 作为单独窗口打开的"创建 Safe"（侧边栏、设置）。
struct CreateSafeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: CreateSafeModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create a Safe").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if let model {
                CreateSafeView(model: model) { dismiss() }
            }
        }
        .frame(width: 620, height: 640)
        .onAppear {
            if model == nil { model = CreateSafeModel(paired: app.signers.first, chainID: app.chainID) }
        }
    }
}

/// 扫另一台签名器的配对码，加成新 Safe 的签名人；它同时配对进这台 Mac（不替换已有的配对）。
struct ScanSignerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 新 Safe 的链：在这条链上核对签名器的地址。
    let chainID: UInt64
    var onScanned: (PairedSigner) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Another Signer").font(.title2.bold())
            Text("On the other iPhone, open UniPass Inkan Signer and tap “Pair with UniPass Inkan Desktop”, then hold its screen up to this Mac's camera. It is also paired with this Mac, so you can ask it to sign from here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PairSignerView(chainID: chainID) {
                onScanned($0)
                dismiss()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// 加一个普通地址当签名人：EIP-55 校验，地址照地址簿的样子显示（首尾 8 位加粗）。
struct AddOwnerAddressSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chainID: UInt64
    var onAdd: (OwnerDraft) -> Void

    @State private var name = ""
    @State private var text = ""

    private var parsed: Result<Address, RecipientInput.Problem> { RecipientInput.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Signer by Address").font(.title2.bold())
            Text("For a hardware wallet or another wallet that will sign in Safe{Wallet}. Check the whole address on that wallet.")
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
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard case .success(let a) = parsed else { return }
                    let n = name.trimmingCharacters(in: .whitespaces)
                    onAdd(OwnerDraft(name: n.isEmpty ? (app.name(for: a) ?? "") : n, address: a))
                    dismiss()
                    // 名字记进地址簿，方便以后显示；合约地址（可能是签名合约）不存，免得被当成收款人。
                    guard !n.isEmpty, app.name(for: a) == nil else { return }
                    Task {
                        guard let rpc = app.rpc(chainID: chainID), let code = try? await rpc.code(at: a), code.isEmpty else { return }
                        app.addressBook.save(name: n, address: a)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .success = parsed { false } else { true } }())
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

// MARK: - 添加已有 Safe

@Observable
final class AddSafeModel {
    enum Phase: Equatable {
        /// review：核对都通过了，列出签名人和门限，用户确认后才加进列表。
        case form, checking, review(ExistingSafe.Review), added(SafeRegistration), refused(String)
    }

    /// 没配对的签名人自己就够门限时，用户勾了确认。
    var acknowledged = false

    /// 读到的创建参数（核对通过或者被拒都列出签名人和门限给用户看）。
    var found: SafeRegistration?

    var addressText = ""
    var chainID: UInt64 = 11_155_111
    var name = ""
    var phase: Phase = .form

    var parsed: Result<Address, RecipientInput.Problem> { RecipientInput.parse(addressText) }

    /// 交易服务给创建参数，自己重算地址；链上读当前状态；签名器离线只能信创建参数，所以创建后改过的不收。
    @MainActor
    func add(app: AppModel) async {
        guard case .success(let address) = parsed else { return }
        phase = .checking
        found = nil
        guard let rpc = app.rpc(chainID: chainID), let sts = app.sts(chainID: chainID) else {
            phase = .refused(L("This network isn't supported."))
            return
        }
        do {
            guard try await !rpc.code(at: address).isEmpty else {
                phase = .refused(L("There is no contract at this address on this network. Check the address and the network."))
                return
            }
            guard let info = try? await sts.safeCreation(address), let factory = info.factoryAddress.flatMap(Address.init(hex:)),
                  let singleton = info.masterCopy.flatMap(Address.init(hex:)), let setup = info.setupData.flatMap(Data.init(hex:)),
                  let salt = info.saltNonce.flatMap(UInt256.init(decimal:)) else {
                phase = .refused(Self.message(.noCreationInfo))
                return
            }
            var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            while n.utf8.count > SafeRegistration.maxNameBytes { n.removeLast() }
            let r: SafeRegistration
            do {
                r = try ExistingSafe.registration(chainID: chainID, safe: address, factory: factory, singleton: singleton,
                                                  setupData: setup, saltNonce: salt, name: n.isEmpty ? nil : n)
            } catch let p as ExistingSafe.Problem {
                phase = .refused(Self.message(p))
                return
            }
            found = r
            // 当前状态两边各读一份：区块链节点和交易服务的 `/safes/{address}/`，不一致就不收。
            async let onChainState = rpc.existingSafeState(address)
            async let serviceInfo = sts.safeInfo(address)
            let onChain = try await onChainState
            guard let service = try await serviceInfo.state else {
                phase = .refused(Self.message(.sourcesDisagree))
                return
            }
            if let p = ExistingSafe.problem(r, onChain: onChain, service: service, signers: app.signers.proxies) {
                phase = .refused(Self.message(p))
                return
            }
            acknowledged = false
            phase = .review(ExistingSafe.Review(r, paired: app.signers.proxies))
        } catch {
            phase = .refused(L("Could not reach the network. Check the connection and try again."))
        }
    }

    @MainActor static func message(_ p: ExistingSafe.Problem) -> String {
        switch p {
        case .noCreationInfo:
            L("Safe's transaction service doesn't know how this Safe was created (for example, it was deployed through another contract). The signer can only accept a Safe whose creation it can check.")
        case .unsupportedFactoryOrVersion:
            L("This Safe wasn't created with an official Safe factory and version that this app supports.")
        case .setupNotDecodable:
            L("This Safe's creation data couldn't be read.")
        case .addressMismatch:
            L("The creation data doesn't produce this address. Don't use this Safe here.")
        case .extraSetupCall:
            L("This Safe ran an extra setup step when it was created. The offline signer can't check what that step did, so it can't be added.")
        case .ownersChanged:
            L("This Safe's signers have changed since it was created. The offline signer can only trust the signers it was created with, so it can't be added.")
        case .thresholdChanged:
            L("This Safe's approval threshold has changed since it was created, so it can't be added.")
        case .hasModules:
            L("This Safe has modules enabled. Modules can move funds without the signers, so it can't be added.")
        case .hasGuard:
            L("This Safe has a transaction guard set, which this app doesn't support yet.")
        case .fallbackHandlerChanged:
            L("This Safe's fallback handler has changed since it was created, so it can't be added.")
        case .singletonChanged:
            L("This Safe's implementation contract has changed since it was created, so it can't be added.")
        case .signerNotOwner:
            L("None of the signers paired with this Mac is one of this Safe's signers.")
        case .sourcesDisagree:
            L("The blockchain node and Safe's transaction service report different signers or settings for this Safe, so it can't be added. Try again later, or set a different node in Settings › Advanced.")
        }
    }

    /// 加进列表。需要确认而没确认时什么都不做。
    @MainActor func confirm(app: AppModel) {
        guard case .review(let review) = phase, review.canAdd(acknowledged: acknowledged) else { return }
        app.addSafe(review.registration)
        phase = .added(review.registration)
    }
}

/// 要添加的 Safe 的签名人和门限：哪几台是这台 Mac 配对的签名器，其他的是谁（地址簿里的名字或者地址）。
struct ExistingSafeOwners: View {
    @Environment(AppModel.self) private var app
    let registration: SafeRegistration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transactions need \(Int(registration.threshold)) of these \(registration.owners.count) signers:")
                .font(.headline)
            ForEach(registration.owners, id: \.self) { owner in
                HStack(alignment: .top, spacing: 10) {
                    let paired = app.signers.contains(owner)
                    Image(systemName: paired ? "iphone" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(paired ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        NamedAddress(name: app.name(for: owner), address: owner)
                        if paired { Text("Paired with this Mac").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

struct AddSafeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = AddSafeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an Existing Safe").font(.title2.bold())
            switch model.phase {
            case .review(let review):
                Text("Check who can approve this Safe's transactions before adding it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ExistingSafeOwners(registration: review.registration)
                if review.needsAcknowledgement {
                    Label {
                        Text("Any \(Int(review.registration.threshold)) of this Safe's signers that aren't paired with this Mac can move its funds without your iPhone signer. The signer's offline checks don't apply to those transactions.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    Toggle("I understand. Add this Safe anyway.", isOn: $model.acknowledged)
                        .toggleStyle(.checkbox)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Add This Safe") { model.confirm(app: app) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!review.canAdd(acknowledged: model.acknowledged))
                }
            case .added(let r):
                Label("Added “\(r.name ?? AddressDisplay.short(r.safe))”", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Register it on your signer by signing its first transaction, or from Settings › Signers & Safes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            default:
                Text("Only a Safe created with an official Safe factory, whose signers and threshold haven't changed since, with no modules or guard, and with your paired signer as a signer.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Network", selection: $model.chainID) {
                    ForEach(SafeCreation.chains, id: \.self) { id in
                        Text(verbatim: Display.network(id) + (Display.isTestnet(id) ? " · " + L("Testnet") : "")).tag(id)
                    }
                }
                TextField("Safe address (0x…)", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if case .failure(let p) = model.parsed, let message = SendFlow.message(p) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                TextField("Name (optional)", text: $model.name).textFieldStyle(.roundedBorder)
                if case .refused(let message) = model.phase {
                    Label { Text(verbatim: message).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "xmark.octagon.fill") }
                        .foregroundStyle(.red)
                    if let found = model.found { ExistingSafeOwners(registration: found) }
                }
                HStack {
                    if model.phase == .checking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Add") { Task { await model.add(app: app) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.phase == .checking || { if case .success = model.parsed { false } else { true } }())
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { model.chainID = app.chainID }
    }
}

/// 一个 Safe 都没有时，主窗口显示这个。
struct NoSafeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ContentUnavailableView {
            Label("No Safe Yet", systemImage: "lock.shield")
        } description: {
            Text("Create a new Safe with your signer as a signer, or add a Safe you already have.")
        } actions: {
            Button("Create a Safe…") { app.creatingSafe = true }.buttonStyle(.borderedProminent)
            Button("Add an Existing Safe…") { app.addingSafe = true }
        }
    }
}
