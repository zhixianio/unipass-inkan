import AppKit
import CoordinatorFlow
import SafeTransactionService
import SwiftUI
import UniPassCore

enum SettingsTab: String {
    case general, safes, submitter, advanced
}

/// 设置（⌘,）：通用、签名器与 Safe、提交账户、高级（交易服务的 API key）。
struct SettingsScreen: View {
    @AppStorage(Self.tabKey) private var tab: SettingsTab = .general

    private static let tabKey = "settings.tab"

    /// 从别处打开设置时先选好页（侧边栏的"添加 Safe…"、首页的"配对签名器…"）。
    static var selectedTab: SettingsTab {
        get { UserDefaults.standard.string(forKey: tabKey).flatMap(SettingsTab.init) ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tabKey) }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Signers & Safes", systemImage: "iphone", value: .safes) { SignerAndSafeSettings() }
            Tab("Submitter Account", systemImage: "paperplane", value: .submitter) { SubmitterAccountSettings() }
            Tab("Advanced", systemImage: "slider.horizontal.3", value: .advanced) {
                Form {
                    RPCNodeSettings()
                    APIKeySettings()
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 620, height: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                LabeledContent("Network") { NetworkBadge(chainID: app.chainID) }
            } footer: {
                if Display.isTestnet(app.chainID) {
                    Text("The network follows your Safe. This Safe is on a test network: its coins have no real value.")
                } else {
                    Text("The network follows your Safe.")
                }
            }
            Section {
                LabeledContent("Language") { Text("Same as the system") }
                Button("Language & Region Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            } footer: {
                Text("To use a different language for this app only, add it under Applications in Language & Region.")
            }
        }
        .formStyle(.grouped)
    }
}

/// 已配对的签名器（可以有几台）、已登记的 Safe。
struct SignerAndSafeSettings: View {
    @Environment(AppModel.self) private var app
    @State private var pairing = false
    @State private var renaming: PairedSigner?
    @State private var unpairing: PairedSigner?
    @State private var registering: SafeRegistration?
    @State private var creating = false
    @State private var adding = false
    @State private var removing: SafeRegistration?

    var body: some View {
        Form {
            Section {
                if app.signers.isEmpty {
                    Text("No signer paired. Every transaction from your Safe is approved on the signer, so pair one first.")
                        .foregroundStyle(.secondary)
                    Button("Pair a Signer…") { pairing = true }
                } else {
                    ForEach(app.signers.all, id: \.signerProxy) { s in
                        PairedSignerRow(signer: s, onRename: { renaming = s }, onUnpair: { unpairing = s })
                    }
                    Button("Pair Another Signer…") { pairing = true }
                }
            } header: {
                Text("Paired Signers")
            } footer: {
                Text("Pair every iPhone that is a signer of your Safes, so this Mac can ask each of them to sign. Pairing the same iPhone again only updates it.")
            }
            Section {
                if app.store.safes.isEmpty {
                    Text("No Safes on this Mac yet.").foregroundStyle(.secondary)
                }
                ForEach(app.store.safes, id: \.self) { r in
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: r.name ?? AddressDisplay.short(r.safe)).font(.body.weight(.medium))
                            HStack(spacing: 8) {
                                NetworkBadge(chainID: r.chainID)
                                Text("\(Int(clamping: r.threshold)) of \(r.owners.count) signers").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(verbatim: AddressDisplay.short(r.safe)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Register with the Signer…") { registering = r }
                        Button { removing = r } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(Text("Remove from This Mac…"))
                    }
                }
                HStack {
                    Button("Create a Safe…") { creating = true }
                    Button("Add an Existing Safe…") { adding = true }
                }
            } header: {
                Text("Safes")
            } footer: {
                Text("A Safe is registered on the signer the first time it signs for it. Removing a Safe here only removes it from this Mac; the Safe and its funds are not affected.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pairing) { PairSignerSheet(another: !app.signers.isEmpty) }
        .sheet(item: $renaming) { RenameSignerSheet(signer: $0) }
        .sheet(item: $registering) { SafeRegistrationSheet(registration: $0) }
        .sheet(isPresented: $creating) { CreateSafeSheet() }
        .sheet(isPresented: $adding) { AddSafeSheet() }
        .confirmationDialog("Remove this Safe from this Mac?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { r in
            Button("Remove", role: .destructive) { app.removeSafe(SafeStore.SafeID(r)) }
        } message: { r in
            Text("“\(r.name ?? AddressDisplay.short(r.safe))” disappears from this app. The Safe on chain and its funds are not affected; you can add it again later.")
        }
        .confirmationDialog("Unpair this signer?", isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
                            presenting: unpairing) { s in
            Button("Unpair", role: .destructive) { app.unpair(s.signerProxy) }
        } message: { s in
            Text("“\(s.name)” is removed from this Mac, and you can't ask it to sign from here until you pair it again. Nothing changes on the signer or in your Safes.")
        }
    }
}

extension SafeRegistration: @retroactive Identifiable {
    public var id: String { safe.checksummed }
}

extension PairedSigner: @retroactive Identifiable {
    public var id: String { signerProxyHex }
}

/// Safe 交易服务的 API key 是可选的：不填也能用，只是有频率限制。
struct APIKeySettings: View {
    enum Message { case saved, removed, failed }

    @State private var keyInput = ""
    @State private var hasKey = SafeAPIKey.keychainValue() != nil
    @State private var message: Message?

    var body: some View {
        Section {
            SecureField(hasKey ? "Saved (enter a new one to replace it)" : "Optional", text: $keyInput)
            HStack {
                Button("Save") { save(keyInput) }.disabled(keyInput.isEmpty)
                if hasKey { Button("Remove", role: .destructive) { save("") } }
            }
            switch message {
            case .saved?: Text("Saved.").font(.caption).foregroundStyle(.secondary)
            case .removed?: Text("Removed. No key will be used.").font(.caption).foregroundStyle(.secondary)
            case .failed?: Text("Could not save the key to the keychain.").font(.caption).foregroundStyle(.red)
            case nil: EmptyView()
            }
        } header: {
            Text("Safe Transaction Service API key")
        } footer: {
            Text("UniPass Inkan Desktop collects and syncs signatures through Safe's official transaction service. It works without a key, limited to 2 requests per second and 5,000 per month; for regular use, get a free key at developer.safe.global. The key is stored only in this Mac's keychain.")
        }
    }

    private func save(_ key: String) {
        do {
            if key.isEmpty { try SafeAPIKey.delete() } else { try SafeAPIKey.save(key) }
            keyInput = ""
            hasKey = SafeAPIKey.keychainValue() != nil
            message = hasKey ? .saved : .removed
        } catch {
            message = .failed
        }
    }
}

/// 每条链的 RPC 节点（设置 › 高级）。默认用 PublicNode 的公共节点；自己填的存钥匙串，界面上只显示打码后的样子。
struct RPCNodeSettings: View {
    @Environment(AppModel.self) private var app
    @State private var editing: EditingChain?

    struct EditingChain: Identifiable {
        let chainID: UInt64
        var id: UInt64 { chainID }
    }

    var body: some View {
        Section {
            ForEach(SafeCreation.chains, id: \.self) { id in
                LabeledContent {
                    HStack {
                        if let url = app.rpcEndpoints.custom[id] {
                            Text(verbatim: RPCEndpoints.masked(url)).font(.system(.caption, design: .monospaced))
                        } else {
                            Text("Default").foregroundStyle(.secondary)
                        }
                        Button("Change…") { editing = EditingChain(chainID: id) }
                    }
                } label: {
                    NetworkBadge(chainID: id)
                }
            }
        } header: {
            Text("Blockchain nodes")
        } footer: {
            Text("By default the app reads the chain through public nodes run by \(RPCEndpoints.defaultProvider). They limit how often you can ask, and they can see which addresses you look up and your IP address. To use your own node or a provider such as Alchemy or Infura, enter its URL. It's stored only in this Mac's keychain.")
        }
        .sheet(item: $editing) { RPCNodeSheet(chainID: $0.chainID) }
    }
}

struct RPCNodeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chainID: UInt64

    @State private var text = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Node for").font(.title2.bold())
                NetworkBadge(chainID: chainID)
            }
            Text("Enter the node's https:// URL. Before saving, the app asks the node which chain it serves.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let url = app.rpcEndpoints.custom[chainID] {
                LabeledContent("Current") { Text(verbatim: RPCEndpoints.masked(url)).font(.system(.caption, design: .monospaced)) }
            } else if let url = EthRPC.defaultURL(chainID: chainID) {
                LabeledContent("Current") {
                    Text("Default: \(url.host(percentEncoded: false) ?? "") (\(RPCEndpoints.defaultProvider))").foregroundStyle(.secondary)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if app.rpcEndpoints.custom[chainID] != nil {
                    Button("Use the Default Node") { save(nil) }
                }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Check and Save") { Task { await check() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func check() async {
        checking = true
        problem = nil
        defer { checking = false }
        switch await RPCEndpoints.validate(text, chainID: chainID) {
        case .success(let url): save(url)
        case .failure(let p): problem = Self.message(p, chainID: chainID)
        }
    }

    private func save(_ url: URL?) {
        do {
            try app.setRPCEndpoint(url, chainID: chainID)
            dismiss()
        } catch {
            problem = L("Could not save the node to the keychain.")
        }
    }

    static func message(_ p: RPCEndpoints.Problem, chainID: UInt64) -> String {
        switch p {
        case .notAURL: L("This isn't a valid URL. It should look like https://…")
        case .notHTTPS: L("Use an https:// URL. Plain http:// is only allowed for a node on this Mac (localhost).")
        case .unreachable: L("Couldn't get an answer from this node. Check the URL and your network.")
        case .wrongChain(let other): F("This node serves %@, not %@.", Display.network(other), Display.network(chainID))
        }
    }
}
