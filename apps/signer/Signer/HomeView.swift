import SignerKit
import SwiftUI
import UniPassCore

/// 首页只回答两件事：现在能不能签、下一步做什么。密钥、签名地址、配对（已有 Safe 之后）都在设置里。
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var choosingPolicy = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                statusSection
                if model.key == nil, model.keyUnreadable {
                    unreadableKeySection
                } else if model.key == nil {
                    createKeySection
                } else {
                    scanSection
                    // 还没有 Safe 时，下一步就是配对；有了 Safe 之后配对放在设置里。
                    if model.store.safes.isEmpty { pairingSection }
                    Section {
                        NavigationLink { SafesView() } label: {
                            LabeledContent { Text(verbatim: "\(model.store.safes.count)") } label: { Label("My Safes", systemImage: "lock.shield") }
                        }
                        NavigationLink { AddressBookView() } label: {
                            LabeledContent { Text(verbatim: "\(model.store.addressBook.count)") } label: { Label("Address book", systemImage: "person.2") }
                        }
                    }
                }
                #if DEBUG
                // 演示和调试工具默认不出现，只在启动参数 `-InkanDemo YES` 时出现；Release 不编译。
                if DebugTools.enabled { debugSection }
                #endif
            }
            .navigationTitle("UniPass Inkan Signer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("Settings"))
                }
            }
            .sheet(isPresented: $scanning) { ScanView() }
            .sheet(isPresented: $choosingPolicy) { PolicyPicker() }
            .fullScreenCover(item: $model.route) { route in
                switch route {
                case .confirm(let a, let ur): ConfirmView(assessment: a, ur: ur)
                case .register(let v, let then): RegisterView(verified: v, then: then)
                case .failure(let message): FailureView(message: message)
                case .signature(let sig, let hash): SignatureView(signature: sig, safeTxHash: hash)
                }
            }
        }
    }

    // MARK: 状态

    /// 大图标 + 一句话 + 要做什么。各项连接的明细和网卡地址在"联网详情"里。
    private var statusSection: some View {
        let offline = model.network.isOffline
        // 还没有密钥时不说"可以签名"。
        let hasKey = model.key != nil
        return Section {
            // 联网就不能签（签名前还会再查一次），没有单独的维护模式。
            VStack(spacing: 8) {
                Image(systemName: offline ? "checkmark.shield.fill" : "wifi.exclamationmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(offline ? Color.green : Color.red)
                Text(!offline ? "Online: cannot sign" : hasKey ? "Offline: ready to sign" : "Offline")
                    .font(.title3.weight(.semibold))
                Text(!offline ? "In Settings, turn on Airplane Mode and turn off Wi-Fi and Bluetooth. Don't use Control Center: its switches only disconnect until the next day."
                     : hasKey ? "This iPhone has no network connection. The signer does not read Bluetooth status, so that it carries no communication framework: make sure Bluetooth is off in Settings."
                     : "Create a signing key to start signing.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            if !offline {
                ConnectionChecklist(status: model.network, onlyConnected: true, showsBluetooth: false)
            } else if model.wifiRadioOn {
                // 只在 Wi-Fi 开着但没连上时提醒，不常驻。
                Label("Wi-Fi is on but not connected. Turn it off in Settings › Wi-Fi: it can join a known network at any time.", systemImage: "wifi")
                    .font(.callout).foregroundStyle(.orange)
            }
            NavigationLink { NetworkDetailsView() } label: { Text("Network details") }
        }
    }

    // MARK: 下一步

    private var createKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Create a signing key", systemImage: "key.fill").font(.headline)
                Text("It is created in this iPhone's security chip and never leaves it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button { choosingPolicy = true } label: { Text("Get started").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let e = model.keyError { Text(e).foregroundStyle(.red).font(.caption) }
        }
    }

    private var unreadableKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("The signing key could not be read", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                Text("Unlock this iPhone and try again. Do not create a new key: this iPhone may still be a signer of your Safe.")
                    .font(.callout).foregroundStyle(.secondary)
                if let e = model.keyError { Text(e).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
            Button { model.loadKey() } label: { Text("Try again").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var scanSection: some View {
        Section {
            // 不用 Label：列表会把 Label 的图标染成强调色，在蓝色按钮上就看不见了，文字还会被挤到右边。
            Button { scanning = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan a QR code")
                }
                .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    private var pairingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Next: pair with UniPass Inkan Desktop", systemImage: "link").font(.headline)
                Text("Open the pairing page in UniPass Inkan Desktop and scan this iPhone's pairing code. The desktop then adds this iPhone as a signer when it creates your Safe.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            NavigationLink { PairingView() } label: { Text("Show pairing code") }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        @Bindable var model = model
        return Section {
            Toggle(isOn: $model.debugIgnoreNetwork) { Text(verbatim: "Ignore network check") }.tint(.orange)
            ForEach(DemoScenario.allCases) { d in
                Button { model.load(demo: d) } label: { Text(verbatim: "Demo: \(d.rawValue)") }
            }
        } header: {
            Text(verbatim: "Debug (not in release builds)")
        }
    }
    #endif
}

/// 联网详情：每种连接的状态和触发"联网"的网卡地址。
struct NetworkDetailsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ConnectionChecklist(status: model.network)
            } footer: {
                Text("Turn Wi-Fi and Bluetooth off in Settings, not in Control Center: Control Center only disconnects them until the next day or a restart. Airplane Mode leaves Bluetooth on, and remembers Wi-Fi or Bluetooth you turned back on while in it.")
            }
            if case .online(let hits) = model.network, !hits.isEmpty {
                Section {
                    ForEach(hits, id: \.self) { Text(verbatim: $0.description).font(.callout.monospaced()) }
                } header: {
                    Text("Network interfaces")
                }
            }
        }
        .navigationTitle("Network details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FailureView: View {
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 56)).foregroundStyle(.red)
                Text(message).multilineTextAlignment(.center)
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.route = nil } } }
        }
    }
}
