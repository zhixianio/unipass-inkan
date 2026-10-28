import LocalAuthentication
import SignerKit
import SwiftUI
import UniPassCore

/// 设置：这台签名器（密钥、签名地址、Face ID 设置、删除密钥）、配对、关于。不放链接，也没有任何会联网的东西。
struct SettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { ThisDeviceView() } label: { Label("This iPhone", systemImage: "iphone") }
                NavigationLink { PairingView() } label: { Label("Pair with UniPass Inkan Desktop", systemImage: "link") }
            }
            Section {
                LabeledContent("Version") { Text(verbatim: Self.version) }
                LabeledContent("License") { Text(verbatim: "Apache-2.0") }
            } header: {
                Text("About")
            } footer: {
                Text("UniPass Inkan is open source. This app never connects to the internet: requests and signatures travel only as QR codes.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// 这台签名器：密钥在哪、本机签名地址、Face ID 设置、删除密钥（两次确认）。
struct ThisDeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var finalDelete = false

    var body: some View {
        List {
            if let key = model.key {
                Section {
                    switch key.kind {
                    case .secureEnclave:
                        Label("The key is in this iPhone's security chip and cannot be exported.", systemImage: "lock.shield.fill")
                    case .softwareDebug:
                        #if DEBUG
                        Label("Software key (debug only, NOT Secure Enclave)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).fontWeight(.bold)
                        #else
                        EmptyView()
                        #endif
                    }
                    if let id = model.identity { SignerAddressBlock(address: id.signerProxy) }
                } header: {
                    Text("Signing key")
                }
                if let policy = model.policy {
                    Section {
                        LabeledContent("Face ID") { Text(policy.title) }
                        Text(policy.summary).font(.footnote).foregroundStyle(.secondary)
                    } footer: {
                        Text("The Face ID setting is chosen when the key is created and cannot be changed. To use a different one, delete the key and create a new one, which has to be added to your Safe as a new signer.")
                    }
                }
                Section {
                    Button("Delete signing key", role: .destructive) { confirmingDelete = true }
                }
            } else if model.keyUnreadable {
                // 只有读不出来时才有这个入口；能读出来的密钥走上面的"删除签名密钥"。
                Section {
                    Label("The signing key could not be read", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    NavigationLink { DeleteUnreadableKeyView() } label: {
                        Text("Delete the unreadable signing key").foregroundStyle(.red)
                    }
                } header: {
                    Text("Signing key")
                }
            } else {
                Section {
                    Text("No signing key on this iPhone.").foregroundStyle(.secondary)
                }
            }
            if let e = model.keyError {
                Section { Text(e).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle("This iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(Text("Delete the signing key?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { finalDelete = true }
        } message: {
            Text("This iPhone will no longer be able to sign for your Safes. The key cannot be exported, so it cannot be recovered.")
        }
        .alert(Text("Delete for good?"), isPresented: $finalDelete) {
            Button("Delete key", role: .destructive) { model.deleteKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("First make sure the other signers of each Safe can still give the required approvals without this iPhone, or replace this iPhone as a signer. Otherwise the Safe's assets may be locked for good.")
        }
    }
}

/// 删除读不出的签名密钥：只写后果，不劝删也不劝不删。要输入确认字符，删之前再过一次设备密码验证。
struct DeleteUnreadableKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var working = false
    @State private var error: String?

    private var word: String { String(localized: "DELETE") }

    /// 知道签名人地址时只列签名人里有它的 Safe（之前删过密钥的话，"我的 Safe"里可能还有旧密钥的 Safe）；不知道时列出全部。
    private var safes: [SignerStore.SafeRecord] {
        guard let signer = model.lastSignerAddress else { return model.store.safes }
        return model.store.safes.filter { $0.owners.contains { Address(hex: $0) == signer } }
    }

    var body: some View {
        List {
            Section {
                Label("The key is gone for good and cannot be recovered. It cannot be exported, and there is no backup.", systemImage: "key.slash")
                Label("Every Safe this key signs for loses this signer. Its other signers have to replace it.", systemImage: "person.2.slash")
                Label("You can then create a new key, but it has a different signer address and has to be added to each Safe as a new signer.", systemImage: "key")
            } header: {
                Text("What deleting does")
            }
            if let address = model.lastSignerAddress {
                Section {
                    SignerAddressBlock(address: address)
                } footer: {
                    Text("Recorded the last time the key could be read.")
                }
            }
            Section {
                ForEach(safes, id: \.self) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        AddressView(info: AddressInfo(address: Address(hex: s.address)!, label: s.name, source: .mySafe), hidesSource: true, compact: true)
                        Text(verbatim: "\(Display.chain(s.chainID)) · \(Display.approvals(s.threshold, of: s.owners.count))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if safes.isEmpty {
                    Text("No registered Safe has this key as a signer.").foregroundStyle(.secondary)
                }
            } header: {
                Text(model.lastSignerAddress == nil ? "Registered Safes" : "Registered Safes with this signer")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.lastSignerAddress == nil, !safes.isEmpty {
                        Text("The signer address is unknown, so every registered Safe is listed. Each was checked to have this iPhone's key at that time as a signer when it was added.")
                    }
                    Text("The key may also be a signer of Safes that were never added here. Registered Safes and the address book are kept.")
                }
            }
            Section {
                TextField(word, text: $typed)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } header: {
                Text("To delete, type \(word)")
            }
            Section {
                Button("Delete signing key", role: .destructive) { delete() }
                    .disabled(typed.trimmingCharacters(in: .whitespaces) != word || working || model.key != nil)
            } footer: {
                Text("Face ID or the passcode is required first.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Delete unreadable key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func delete() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.deleteUnreadableKey()
                dismiss()
            } catch let e as LAError where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
                // 取消验证：什么也不做。
            } catch KeyStore.Failure.keyReadable {
                self.error = String(localized: "The signing key can be read now, so it was not deleted.")
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
