import SignerKit
import SwiftUI
import UniPassCore

/// 签好的结果：`unipass-signature` 二维码，给 UniPass Inkan 桌面端扫。
struct SignatureView: View {
    let signature: SignerSignature
    let safeTxHash: Data
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Label("Signed", systemImage: "checkmark.seal.fill").font(.title2.weight(.bold)).foregroundStyle(.green)
                    URQRCode(ur: signature.ur)
                    Text("Show this code to UniPass Inkan Desktop.").font(.callout)
                    VStack(spacing: 4) {
                        Text("Transaction fingerprint").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: Display.shortHash(safeTxHash)).font(.system(.title3, design: .monospaced).weight(.semibold))
                    }
                }
                .padding()
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.route = nil } } }
        }
    }
}

/// 登记 Safe：地址已经按创建参数离线核对，并且本机在 owner 里。列出全部签名人和所需同意人数给用户确认。
/// `then` 不为空时是"首次见到这个 Safe"：登记后直接进入那笔交易的确认页。
/// 名字必须由用户在这里自己起，不用桌面端给的名字（否则对方可以把自己的 Safe 叫成"Main vault"冒充你的 Safe）。
struct RegisterView: View {
    let verified: SafeAddress.VerifiedSafe
    let then: EthSignRequest?
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var registration: SafeRegistration { verified.registration }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool { !trimmedName.isEmpty && model.store.isNameTaken(trimmedName) }

    var body: some View {
        NavigationStack {
            List {
                if then != nil {
                    Section {
                        Label("First time seeing this Safe", systemImage: "sparkles").font(.headline)
                        Text("This signing request is for a Safe that is not in My Safes yet. Check its signers below. Add it and continue to the transaction?")
                            .font(.callout)
                    }
                }
                Section {
                    Label("Address verified offline from its creation parameters", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    LabeledContent("Network") { Text(verbatim: Display.chain(registration.chainID)) }
                    // 完整地址（前后各 8 位加粗）；不显示桌面端给的名字。
                    AddressView(info: AddressInfo(address: registration.safe, label: nil, source: .unknown), hidesSource: true)
                    DisclosureGroup("Technical details") {
                        LabeledContent("Version") { Text(verbatim: "Safe\(verified.initCode.isL2 ? "L2" : "") \(verified.initCode.version)") }
                        // 核对时已经要求是零地址或同版本官方的 CompatibilityFallbackHandler（SafeAddress.verify）。
                        LabeledContent("Fallback handler") {
                            if registration.fallbackHandler == .zero {
                                Text("None")
                            } else {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(verbatim: LabelLibrary.builtIn.lookup(chainID: registration.chainID, address: registration.fallbackHandler)?.name ?? "")
                                    Text(verbatim: Explanation.shortAddress(registration.fallbackHandler)).font(.caption.monospaced())
                                }
                            }
                        }
                    }
                }
                Section {
                    Text(Display.approvals(registration.threshold, of: registration.owners.count)).font(.headline)
                    ForEach(registration.owners, id: \.self) { o in owner(o) }
                } header: {
                    Text("Signers")
                } footer: {
                    Text("This proves only the signers and required approvals the Safe was created with. If they were changed later, this iPhone does not know about it.")
                }
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    if nameTaken {
                        Text("A Safe or an address book entry already has this name. Use a different one.").foregroundStyle(.red)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Button(then == nil ? "Register this Safe" : "Add and continue") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedName.isEmpty || nameTaken || saving)
                } header: {
                    Text("Name this Safe")
                } footer: {
                    Text("Type a name on this iPhone. The name sent by UniPass Inkan Desktop is not used. It must differ from your other Safes and address book entries. Saving asks for Face ID.")
                }
            }
            .navigationTitle(then == nil ? "Register Safe" : "New Safe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.route = nil } } }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await model.register(verified, name: trimmedName, then: then) } catch {
                if !AppModel.isCancellation(error) { self.error = AppModel.describe(error) }
            }
        }
    }

    /// 本机标"本机"，地址簿里的标名字，其余标"不在地址簿"。
    @ViewBuilder private func owner(_ o: Address) -> some View {
        if o == verified.signer {
            VStack(alignment: .leading, spacing: 2) {
                Badge(text: String(localized: "This iPhone"), color: .blue)
                AddressView(info: AddressInfo(address: o, label: nil, source: .unknown), hidesSource: true)
            }
        } else if let b = model.store.bookEntries.first(where: { $0.address == o }) {
            AddressView(info: AddressInfo(address: o, label: b.label, source: .addressBook))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Badge(text: String(localized: "Not in address book"), color: .gray)
                AddressView(info: AddressInfo(address: o, label: nil, source: .unknown), hidesSource: true)
            }
        }
    }
}

struct SafesView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        let _ = model.storeRevision
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(model.store.safes, id: \.self) { s in
                VStack(alignment: .leading, spacing: 4) {
                    AddressView(info: AddressInfo(address: Address(hex: s.address)!, label: s.name, source: .mySafe), hidesSource: true, compact: true)
                    Text(verbatim: "\(Display.chain(s.chainID)) · \(Display.approvals(s.threshold, of: s.owners.count))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        Task {
                            do { try await model.removeSafe(s) } catch {
                                if !AppModel.isCancellation(error) { self.error = AppModel.describe(error) }
                            }
                        }
                    }
                }
            }
            if model.store.safes.isEmpty {
                Text("No Safes yet. Scan a Safe code or a signing request from UniPass Inkan Desktop.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("My Safes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddressBookView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        let _ = model.storeRevision
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(model.store.addressBook, id: \.self) { b in
                AddressView(info: AddressInfo(address: Address(hex: b.address)!, label: b.label, source: .addressBook), hidesSource: true, compact: true)
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            Task {
                                do { try await model.removeFromAddressBook(b) } catch {
                                    if !AppModel.isCancellation(error) { self.error = AppModel.describe(error) }
                                }
                            }
                        }
                    }
            }
            if model.store.addressBook.isEmpty {
                Text("New addresses are added here only after you confirm them on this iPhone.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Address book")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 配对：`unipass-pairing` 二维码给 UniPass Inkan 桌面端扫。
struct PairingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                TextField("Device name", text: $model.deviceName)
            }
            if let p = model.pairing {
                Section {
                    URQRCode(ur: p.ur).frame(maxWidth: .infinity)
                    SignerAddressBlock(address: p.signerProxy)
                } footer: {
                    Text("UniPass Inkan Desktop adds this address as a signer when it creates the Safe.")
                }
            }
        }
        .navigationTitle("Pair with UniPass Inkan Desktop")
        .navigationBarTitleDisplayMode(.inline)
    }
}
