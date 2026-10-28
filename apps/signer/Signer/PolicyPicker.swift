import SignerKit
import SwiftUI
import UniPassCore

extension BiometryPolicy {
    var title: String {
        switch self {
        case .anyEnrolled: String(localized: "Any enrolled face")
        case .currentSet: String(localized: "Only the faces enrolled now")
        }
    }

    /// 一句话，用在 设置 › 本机。
    var summary: String {
        switch self {
        case .anyEnrolled: String(localized: "Keeps working after Face ID enrollment changes")
        case .currentSet: String(localized: "Stops working for good if Face ID enrollment changes")
        }
    }

    /// 选择页上每个选项的取舍：一句话。界面不推荐任何一项。
    var tradeoff: String {
        switch self {
        case .currentSet: String(localized: "Safer: nobody can sign by adding their own face. But any Face ID change disables the key for good, so it is easier to lose.")
        case .anyEnrolled: String(localized: "Keeps working when Face ID changes. But anyone who knows your passcode can add their face and sign.")
        }
    }

    /// "怎么选？"里的一句：什么情况下这一项的代价可以接受。
    var whenToChoose: String {
        switch self {
        case .currentSet: String(localized: "Your Safe has enough other signers to replace this iPhone if the key stops working.")
        case .anyEnrolled: String(localized: "Nobody else knows your passcode, and you may change Face ID later.")
        }
    }

    /// 选择页上的顺序。
    static let pickerOrder: [BiometryPolicy] = [.currentSet, .anyEnrolled]
}

/// 生成密钥：先选 Face ID 设置（生成后不能改），再生成，然后显示完成页（签名人地址 + 下一步配对）。
/// 不预选、不推荐：用户选了一项之后才能生成。两个选项的行为和生成逻辑在 SignerKit 里。
struct PolicyPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: BiometryPolicy?
    @State private var generated = false

    var body: some View {
        NavigationStack {
            Group {
                if generated, let id = model.identity { done(id.signerProxy) } else { picker }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 选择

    private var picker: some View {
        List {
            Section {
                ForEach(BiometryPolicy.pickerOrder) { policy in
                    Button { selection = policy } label: { option(policy) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("Approve each signature with Face ID. You can't change this later.")
                    .textCase(nil).font(.subheadline).foregroundStyle(.secondary)
            } footer: {
                Text("The key can't be exported and is lost if this iPhone is erased or replaced, so your Safe needs other signers. Either way, turn on Stolen Device Protection in Settings › Face ID & Passcode.")
            }
            Section {
                DisclosureGroup("How to choose?") {
                    ForEach(BiometryPolicy.pickerOrder) { policy in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.title).font(.subheadline.weight(.semibold))
                            Text(policy.whenToChoose).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if !SecureEnclaveSigningKey.isAvailable {
                Section {
                    Text("This device has no Secure Enclave. A debug software key will be created, and this setting does not apply to it.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if let e = model.keyError {
                Section { Text(e).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle("Face ID setting")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                guard let selection else { return }
                model.generateKey(policy: selection)
                if model.key != nil { generated = true }
            } label: {
                Text("Create signing key").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(selection == nil)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func option(_ policy: BiometryPolicy) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selection == policy ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selection == policy ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(policy.title).font(.headline)
                Text(policy.tradeoff).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 完成

    private func done(_ signer: Address) -> some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("Signing key created").font(.title3.weight(.semibold))
                    Text("Stored in this iPhone's security chip. It never leaves it.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                SignerAddressBlock(address: signer)
            }
            Section {
                NavigationLink { PairingView() } label: { Text("Next: pair with UniPass Inkan Desktop").fontWeight(.semibold) }
            }
        }
        .navigationTitle("Signing key")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
