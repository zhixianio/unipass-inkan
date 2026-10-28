import SignerKit
import SwiftUI
import UniPassCore

/// "我的 Safe"和地址簿没通过验签或读不出来时：说明是哪种情况、只读意味着什么，列出文件里的内容，
/// 给出能做的事和各自的后果。不给建议。
struct StoreStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let status = model.storeStatus
        let contents = model.store.unverifiedContents
        let adoption = model.identity.flatMap { model.store.adoption(signerAddress: $0.signerProxy) }
        List {
            Section {
                Text(Self.explanation(status))
                if case .unreadable(let detail) = status {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
                Text("Until this is resolved they are read-only and not used to check transactions: signing requests for these Safes are refused, and these addresses are not recognized.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let contents {
                Section {
                    ForEach(contents.safes, id: \.self) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            if adoption?.droppedSafes.contains(s) == true {
                                Badge(text: String(localized: "This iPhone is not a signer"), color: .gray)
                            }
                            AddressView(info: AddressInfo(address: Address(hex: s.address)!, label: s.name, source: .mySafe), hidesSource: true, compact: true)
                            Text(verbatim: "\(Display.chain(s.chainID)) · \(Display.approvals(s.threshold, of: s.owners.count))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if contents.safes.isEmpty { Text("None").foregroundStyle(.secondary) }
                } header: {
                    Text("Safes in the file")
                }
                Section {
                    ForEach(contents.addressBook, id: \.self) { b in
                        AddressView(info: AddressInfo(address: Address(hex: b.address)!, label: b.label, source: .addressBook), hidesSource: true, compact: true)
                    }
                    if contents.addressBook.isEmpty { Text("None").foregroundStyle(.secondary) }
                } header: {
                    Text("Address book in the file")
                }
            }
            if let adoption {
                Section {
                    Button("Sign and use this data") { run { try await model.adoptStoreData() } }
                        .disabled(working)
                } footer: {
                    Text(adoption.droppedSafes.isEmpty
                         ? "Signs the data above with this iPhone's signing key (Face ID) and uses it from now on. Check that every Safe and address is one you added."
                         : "Signs the data above with this iPhone's signing key (Face ID) and uses it from now on. Check that every Safe and address is one you added. Safes that do not have this iPhone as a signer are not kept.")
                }
            }
            if status == .cannotVerify || status.isUnreadable {
                Section {
                    Button("Try again") { model.loadKey() }
                        .disabled(working)
                } footer: {
                    Text("Reads the signing key and the file again, for example after unlocking this iPhone.")
                }
            }
            Section {
                Button("Set aside and start empty") { run { try await model.setAsideStoreData() } }
                    .disabled(working)
            } footer: {
                Text("The file is renamed and kept on this iPhone, but no longer used. My Safes and the address book start empty, and each Safe has to be added again. Face ID or the passcode is required first.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("My Safes and address book")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: status) { _, new in if new == .ready { dismiss() } }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch {
                if !AppModel.isCancellation(error) { self.error = AppModel.describe(error) }
            }
        }
    }

    static func explanation(_ status: SignerStore.Status) -> LocalizedStringKey {
        switch status {
        case .ready: ""
        case .unsigned: "My Safes and the address book were saved by an earlier version without a signature, so this iPhone cannot tell whether they were changed since."
        case .signedByAnotherKey: "My Safes and the address book were signed by a different key, not this iPhone's current signing key. This happens after the signing key was deleted and a new one created, or if someone replaced the file."
        case .changedAfterSigning: "My Safes and the address book were changed after they were signed. They may have been tampered with."
        case .cannotVerify: "The signing key could not be read, so My Safes and the address book cannot be checked."
        case .unreadable: "The file with My Safes and the address book could not be read."
        }
    }
}

extension SignerStore.Status {
    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}
