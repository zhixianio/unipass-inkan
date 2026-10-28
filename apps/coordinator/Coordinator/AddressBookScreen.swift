import CoordinatorFlow
import SwiftUI
import UniPassCore

/// 地址簿：发送时选收款人、在交易摘要里显示名字。只存在这台 Mac 上；
/// 签名器有自己的地址簿，签名时以签名器上的为准。
struct AddressBookScreen: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Editing?

    struct Editing: Identifiable {
        var id: String { original?.id ?? "new" }
        var original: AddressBook.Entry?
    }

    var body: some View {
        List {
            ForEach(app.addressBook.entries) { entry in
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.name).font(.body.weight(.medium))
                        AddressText(address: entry.address, font: .system(.caption, design: .monospaced))
                    }
                    Spacer()
                    CopyButton(text: entry.addressHex)
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Edit…") { editing = Editing(original: entry) }
                    Button("Delete", role: .destructive) { app.addressBook.remove(entry.address) }
                }
            }
        }
        .overlay {
            if app.addressBook.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Addresses", systemImage: "person.crop.rectangle.stack")
                } description: {
                    Text("Save the people and accounts you send to, so transactions show their names. You can also save a new recipient when you send.")
                } actions: {
                    Button("Add Address…") { editing = Editing() }
                }
            }
        }
        .navigationTitle("Address Book")
        .toolbar {
            ToolbarItem {
                Button { editing = Editing() } label: { Label("Add Address", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { AddressEditor(original: $0.original) }
    }
}

struct AddressEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let original: AddressBook.Entry?

    @State private var name = ""
    @State private var addressText = ""
    /// 签名合约地址不能存成收款人；nil = 还在查。
    @State private var isSigner: Bool?

    private var parsed: Result<Address, RecipientInput.Problem> { RecipientInput.parse(addressText) }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Address", text: $addressText)
                .font(.system(.body, design: .monospaced))
                .disabled(original != nil)
            if case .failure(let p) = parsed, let message = SendFlow.message(p) {
                Text(message).foregroundStyle(.red).font(.caption)
            }
            if isSigner == true {
                Text("This is a signer's address, not a wallet: it belongs to the signing contract of a Safe signer, and anything sent to it is lost forever. It can't be saved as a recipient.")
                    .foregroundStyle(.red).font(.caption)
            }
        }
        .task(id: addressText) {
            isSigner = nil
            guard case .success(let a) = parsed else { return }
            isSigner = await app.checkSignerContract(a, chainID: app.chainID)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if case .success(let a) = parsed {
                        app.addressBook.save(name: name, address: a)
                        dismiss()
                    }
                }
                .disabled({ if case .success = parsed { false } else { true } }() || isSigner != false || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 520)
        .onAppear {
            name = original?.name ?? ""
            addressText = original?.addressHex ?? ""
        }
    }
}
