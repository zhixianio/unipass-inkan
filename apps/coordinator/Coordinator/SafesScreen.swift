import CoordinatorFlow
import SwiftUI
import UniPassCore

/// 登记 Safe：显示登记码给签名器扫。签名器根据创建参数自己算出地址核对，
/// 只有登记过的 Safe 才会签。设置里的"在签名器上登记…"和欢迎引导共用。
struct SafeRegistrationView: View {
    @Environment(AppModel.self) private var app
    let registration: SafeRegistration
    @State private var onChain: Result<(owners: [Address], threshold: UInt256), Error>?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if localCheck != nil {
                        AnimatedURView(ur: registration.ur)
                        Text("Scan this code from the home screen of UniPass Inkan Signer to register this Safe. The signer computes the address from the creation parameters on its own.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        Text("The creation parameters do not match the address, so no registration code is shown.").foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Form {
                Section {
                    Text("Usually you don't need this: the first signing request for a Safe also registers it on the signer. Use it to register a Safe without signing anything.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Safe") {
                    LabeledContent("Name") { Text(verbatim: registration.name ?? AddressDisplay.short(registration.safe)) }
                    LabeledContent("Network") { NetworkBadge(chainID: registration.chainID) }
                    LabeledContent("Address") { AddressText(address: registration.safe) }
                    LabeledContent("Threshold") { Text(verbatim: "\(registration.threshold) / \(registration.owners.count)") }
                    ForEach(Array(registration.owners.enumerated()), id: \.offset) { i, owner in
                        LabeledContent {
                            AddressText(address: owner, font: .system(.caption, design: .monospaced))
                        } label: {
                            if let s = app.signers.signer(owner) {
                                Text("Owner \(i + 1) (\(s.name))")
                            } else {
                                Text("Owner \(i + 1)")
                            }
                        }
                    }
                }
                Section("Checks") {
                    if let version = localCheck {
                        CheckRow(Text("The address computed from the creation parameters matches (official Safe \(version))"), ok: true)
                    } else {
                        CheckRow(Text("The address computed from the creation parameters does not match"), ok: false)
                    }
                    onChainRow
                    let inSafe = app.signers.inSafe(registration.owners)
                    if app.signers.isEmpty {
                        CheckRow(Text("No signer paired yet"), ok: nil)
                    } else if inSafe.isEmpty {
                        CheckRow(Text("None of the signers paired with this Mac is an owner of this Safe"), ok: false)
                    }
                    ForEach(inSafe, id: \.signerProxy) { signer in
                        CheckRow(Text("“\(signer.name)” is an owner of this Safe"), ok: true)
                        if signer.biometryPolicy == .currentSet {
                            let margin = PairedSigner.hasMarginWithoutThisSigner(owners: registration.owners.count, threshold: Int(registration.threshold))
                            Label(margin ? "The signer's key only works with the faces enrolled now; without it the other owners still meet the threshold."
                                         : "The signer's key only works with the faces enrolled now. If it stops working, the other owners cannot meet the threshold and this Safe can no longer sign. Add owners, or switch the signer to “Any enrolled face”.",
                                  systemImage: margin ? "info.circle" : "exclamationmark.triangle")
                                .foregroundStyle(margin ? Color.secondary : Color.orange)
                        }
                    }
                    Text("The creation parameters only prove the owners the Safe was created with. If the owners have changed since, register it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if app.isDeveloper {
                    Section("Creation parameters (debug)") {
                        HexField(label: "SafeProxyFactory", value: registration.proxyFactory.checksummed)
                        HexField(label: "singleton", value: registration.singleton.checksummed)
                        HexField(label: "saltNonce", value: registration.saltNonce.description)
                        HexField(label: "fallbackHandler", value: registration.fallbackHandler.checksummed)
                        HexField(label: "CBOR", value: "\(registration.ur.cbor.count) B")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)
        }
        .task(id: registration.safe) { await checkOnChain() }
    }

    /// 本机核对通过时返回 Safe 版本。
    private var localCheck: String? {
        try? registration.verified().version
    }

    @ViewBuilder private var onChainRow: some View {
        switch onChain {
        case nil:
            HStack { ProgressView().controlSize(.small); Text("Reading owners and threshold on chain…") }
        case .success(let v)?:
            if v.owners == registration.owners && v.threshold == UInt256(registration.threshold) {
                CheckRow(Text("The owners and threshold on chain match the creation parameters"), ok: true)
            } else {
                CheckRow(Text("On chain it is now \(v.threshold.description) / \(v.owners.count), not what the Safe was created with. Register it again after changing owners."), ok: false)
            }
        case .failure:
            CheckRow(Text("Could not read the chain. Check the network."), ok: nil)
        }
    }

    private func checkOnChain() async {
        onChain = nil
        guard let rpc = app.rpc(chainID: registration.chainID) else { return }
        do {
            let owners = try await rpc.safeOwners(registration.safe)
            let threshold = try await rpc.safeThreshold(registration.safe)
            onChain = .success((owners, threshold))
        } catch {
            onChain = .failure(error)
        }
    }
}

/// 设置里的"在签名器上登记…"。
struct SafeRegistrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let registration: SafeRegistration

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Register with the Signer").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            SafeRegistrationView(registration: registration)
        }
        .frame(width: 880, height: 620)
    }
}
