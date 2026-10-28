import CoordinatorFlow
import SwiftUI
import UniPassCore

/// 配对：扫签名器的配对码，核对后直接保存（不再要求用户逐组核对地址；
/// 防偷换公钥由签名器登记 Safe 时检查"自己在 owner 里"）。欢迎引导（第一台）、设置里的"再配对一台"、
/// 创建 Safe 时加另一台签名器共用；同一台再配对一次只更新它的信息。
///
/// 只保存核对通过的（`PairingCheck`）：factory 和 verifiers 是规范值、用 `chainID` 那条链的节点调 `getSigner`
/// 算出的地址一致、已配对过的 proxy 没换公钥。没核对成（网络）的也不保存，让用户再扫一次。
struct PairSignerView: View {
    @Environment(AppModel.self) private var app
    /// 在哪条链上核对：当前 Safe 所在的链（还没有 Safe 时是 `AppModel.chainID` 的默认值），创建 Safe 时是新 Safe 的链。
    var chainID: UInt64?
    var onPaired: (PairedSigner) -> Void = { _ in }

    @State private var scan = ScanModel(acceptedTypes: [SignerPairing.urType])
    @State private var checking: SignerPairing?
    @State private var problem: Problem?

    enum Problem {
        case unreadable
        case refused(SignerPairing, PairingCheck)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let checking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Received the pairing code from “\(checking.name)”. Checking its address on chain…")
                }
            } else {
                URScannerView(model: scan, prompt: "Open the pairing page in UniPass Inkan Signer on your iPhone\nand hold the screen up to this Mac's camera.")
                if let problem { Self.message(problem) }
            }
        }
        .onAppear {
            scan.onResult = { received($0) }
            Task { await scan.start() }
        }
        .onDisappear { scan.stop() }
    }

    @ViewBuilder static func message(_ problem: Problem) -> some View {
        switch problem {
        case .unreadable:
            Label("This pairing code could not be read. Open the pairing page on the signer again.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .refused(_, .unverified):
            Label("The signer's address could not be checked on chain, so it wasn't paired. Check the network and scan again.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        case .refused(let p, .mismatch(let onChain)):
            Label("The address from “\(p.name)” does not match the one computed on chain (\(onChain.checksummed)). Nothing was saved. Open the pairing page on the signer and scan again.",
                  systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .refused(let p, .notCanonical):
            Label("The pairing code from “\(p.name)” doesn't use the standard signer contracts, so it can't be paired. Nothing was saved.",
                  systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .refused(let p, .keyChanged):
            Label("“\(p.name)” has the address of a signer that is already paired, but a different key. Nothing was saved. If that signer was reset, unpair the old one first.",
                  systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .refused(_, .ok):
            EmptyView()
        }
    }

    #if DEBUG
    /// testvectors/webauthn/device/signer-key.json（iPhone 15 Pro，xyz.unipass.signer，.biometryAny）。
    static let testVectorPairing = SignerPairing(
        x: Data(hex: "0x9412d01c528c544a603df018722a38f1a982388e3c688fcc37bfafae34a272dd")!,
        y: Data(hex: "0x19dc995467d9a5cf62f18a144cd44d52bf17553155065e2ca73977d0ce24469d")!,
        name: "iPhone 15 Pro (test vector)",
        biometryPolicy: .anyEnrolled,
        signerProxy: Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!,
        verifiers: Data(hex: "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")!,
        signerFactory: Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!
    )
    #endif

    private func received(_ ur: UR) {
        guard let p = try? SignerPairing(ur: ur) else {
            refuse(.unreadable)
            return
        }
        // factory 和 verifiers 不对的，不用去链上问。
        guard PairingCheck.isCanonical(p) else {
            refuse(.refused(p, .notCanonical))
            return
        }
        problem = nil
        checking = p
        Task {
            var onChain: Address?
            if let rpc = app.rpc(chainID: chainID ?? app.chainID) {
                onChain = try? await rpc.webAuthnSigner(factory: p.signerFactory, x: p.x, y: p.y, verifiers: p.verifiers)
            }
            checking = nil
            let result = PairingCheck.check(p, onChain: onChain, paired: app.signers)
            guard result == .ok, let stored = try? app.pair(PairedSigner(p, verifiedOnChain: true)) else {
                refuse(.refused(p, result == .ok ? .keyChanged : result))
                return
            }
            onPaired(stored)
        }
    }

    private func refuse(_ p: Problem) {
        problem = p
        scan.reset()
        Task { await scan.start() }
    }
}

/// 已配对签名器的信息（设置里的"签名器与 Safe"）。
struct PairedSignerDetails: View {
    @Environment(AppModel.self) private var app
    let paired: PairedSigner

    var body: some View {
        LabeledContent("Address in the Safe") { AddressText(address: paired.signerProxy, font: .system(.callout, design: .monospaced)) }
        LabeledContent("Key fingerprint") { Text(verbatim: paired.fingerprintText).font(.system(.callout, design: .monospaced)) }
        LabeledContent("Face ID") { Text(Self.policyText(paired.biometryPolicy)) }
        LabeledContent("Paired on", value: paired.pairedAt.formatted(date: .abbreviated, time: .shortened))
        if paired.verifiedOnChain {
            CheckRow(Text("Address checked on chain"), ok: true)
        } else {
            Label("The address could not be checked on chain when pairing (network problem). The signer checks that it is an owner when you register a Safe.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if let notice = paired.biometryNotice {
            Label { Text(notice) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.orange)
        }
        if app.isDeveloper {
            DisclosureGroup("Technical details (debug)") {
                HexField(label: "Public key x", value: paired.x.hexString)
                HexField(label: "Public key y", value: paired.y.hexString)
                HexField(label: "verifiers", value: paired.verifiers.hexString)
                HexField(label: "signer factory", value: paired.signerFactory.checksummed)
            }
        }
    }

    static func policyText(_ policy: SignerBiometryPolicy?) -> LocalizedStringKey {
        switch policy {
        case .anyEnrolled: "Any enrolled face"
        case .currentSet: "Only the faces enrolled now"
        case nil: "None (debug software key)"
        }
    }
}

/// 设置里的"配对签名器"："再配对一台"加进列表；扫到已配对过的那台时只更新它。
struct PairSignerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 已经配对过至少一台。
    var another = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(another ? "Pair Another Signer" : "Pair a Signer").font(.title2.bold())
            Text("On your iPhone, open UniPass Inkan Signer and tap “Pair with UniPass Inkan Desktop”, then hold the screen up to this Mac's camera.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PairSignerView { _ in dismiss() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// 已配对的一台：名字、地址，展开看详情；改名、解除配对。
struct PairedSignerRow: View {
    let signer: PairedSigner
    var onRename: () -> Void
    var onUnpair: () -> Void

    var body: some View {
        DisclosureGroup {
            PairedSignerDetails(paired: signer)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title3).foregroundStyle(.tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: signer.name).font(.body.weight(.medium))
                    Text(verbatim: AddressDisplay.short(signer.signerProxy)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename…", action: onRename)
                Button("Unpair…", role: .destructive, action: onUnpair)
            }
        }
    }
}

/// 给一台签名器改这台 Mac 上的名字（只用来显示）。
struct RenameSignerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let signer: PairedSigner

    @State private var name = ""
    @State private var problem: PairedSigners.RenameProblem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Signer").font(.title2.bold())
            Text("The name is only used on this Mac, to tell your signers apart.").foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            switch problem {
            case .empty?: Text("Enter a name.").foregroundStyle(.red)
            case .taken?: Text("Another signer already has this name.").foregroundStyle(.red)
            case nil: EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { name = signer.name }
    }

    private func save() {
        problem = app.renameSigner(signer.signerProxy, to: name)
        if problem == nil { dismiss() }
    }
}
