import AppKit
import CoordinatorFlow
import SwiftUI
import UniPassCore

@main
struct CoordinatorApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        // 单窗口：钱包只有一个主窗口，没有"新建窗口"。
        Window("UniPass Inkan Desktop", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 640)
        }
        .commands { AppCommands(app: app) }
        Settings {
            SettingsScreen().environment(app)
        }
        #if DEBUG
        // 讲解窗口（攻击演示）和开发者窗口：不进"窗口"菜单、不恢复、启动时不打开，只能从快捷键或开发者菜单打开。
        Window(Text("Attack Demo Presenter", tableName: "AttackDemo"), id: AttackDemoState.windowID) {
            AttackDemoPresenterView().environment(app)
        }
        .defaultSize(width: 560, height: 520)
        .commandsRemoved()
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        Window("Developer", id: DeveloperWindow.id) {
            DeveloperWindow().environment(app)
        }
        .defaultSize(width: 980, height: 680)
        .commandsRemoved()
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}

enum Page: String, CaseIterable, Identifiable {
    case home, activity, addressBook

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Assets"
        case .activity: "Activity"
        case .addressBook: "Address Book"
        }
    }

    var symbol: String {
        switch self {
        case .home: "wallet.bifold"
        case .activity: "clock.arrow.circlepath"
        case .addressBook: "person.crop.rectangle.stack"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.onboarded {
                NavigationSplitView {
                    List(selection: Binding<Page?>(get: { app.page }, set: { if let p = $0 { app.page = p } })) {
                        ForEach(Page.allCases) { page in
                            Label(page.title, systemImage: page.symbol)
                                .badge(page == .activity ? app.safe?.pendingCount ?? 0 : 0)
                                .tag(page)
                        }
                    }
                    .disabled(app.safe == nil)
                    .safeAreaInset(edge: .top) {
                        VStack(spacing: 8) {
                            SafeSwitcher()
                            HStack(spacing: 8) {
                                Button { app.creatingSafe = true } label: { Label("Create Safe", systemImage: "plus").frame(maxWidth: .infinity) }
                                Button { app.addingSafe = true } label: { Label("Add Safe", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity) }
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                    }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
                } detail: {
                    if let safe = app.safe {
                        MainPages().environment(safe)
                    } else {
                        NoSafeView()
                    }
                }
                .sheet(isPresented: $app.creatingSafe) { CreateSafeSheet() }
                .sheet(isPresented: $app.addingSafe) { AddSafeSheet() }
            } else {
                WelcomeView()
            }
        }
    }
}

/// 有 Safe 时的三个页面，以及发送 / 接收（当前 Safe 由上层放进环境）。
struct MainPages: View {
    @Environment(AppModel.self) private var app
    @Environment(SafeState.self) private var safe

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.page {
            case .home: HomeScreen()
            case .activity: ActivityScreen()
            case .addressBook: AddressBookScreen()
            }
        }
        // 换了 Safe 就重建页面，各页的 .task 重新读余额和交易。
        .id(SafeStore.SafeID(safe.registration))
        .sheet(isPresented: $app.sending) { SendFlow().environment(safe) }
        .sheet(isPresented: $app.receiving) { ReceiveSheet(safe: safe) }
    }
}

/// 侧边栏顶部的 Safe 卡片：名字、网络（测试网有标记）；点开是 Safe 列表，用来切换。创建、添加在卡片下面的两个按钮。
struct SafeSwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            if app.store.safes.isEmpty {
                Text("No Safes on this Mac yet.")
            }
            // inline Picker：菜单里当前的 Safe 前面有系统的勾。
            Picker(selection: Binding(get: { app.store.current.map(SafeStore.SafeID.init) },
                                      set: { if let id = $0 { app.selectSafe(id) } })) {
                ForEach(app.store.safes, id: \.self) { r in
                    Text(verbatim: label(r)).tag(Optional(SafeStore.SafeID(r)))
                }
            } label: {
                Text("Safes")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    if let safe = app.safe {
                        Text(verbatim: safe.name).font(.headline).lineLimit(1)
                        NetworkBadge(chainID: safe.chainID)
                    } else {
                        Text("No Safe Yet").font(.headline)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func label(_ r: SafeRegistration) -> String {
        "\(r.name ?? AddressDisplay.short(r.safe)) · \(Display.network(r.chainID))"
    }
}

/// 网络名；测试网加一个醒目的"测试网"标记。
struct NetworkBadge: View {
    let chainID: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: Display.network(chainID)).font(.caption).foregroundStyle(.secondary)
            if Display.isTestnet(chainID) {
                Text("Testnet")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.orange)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// 菜单栏：照 macOS 惯例。
struct AppCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About UniPass Inkan Desktop") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Send…") {
                app.page = .home
                app.sending = true
            }
            .keyboardShortcut("n")
            .disabled(!app.onboarded || !app.canSend)
            Button("Receive…") {
                app.page = .home
                app.receiving = true
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!app.onboarded || app.safe == nil)
            Divider()
            Button("Create a Safe…") { app.creatingSafe = true }
                .disabled(!app.onboarded)
            Button("Add an Existing Safe…") { app.addingSafe = true }
                .disabled(!app.onboarded)
        }
        CommandGroup(before: .sidebar) {
            Button("Refresh") { Task { await app.refresh() } }
                .keyboardShortcut("r")
                .disabled(!app.onboarded)
            Divider()
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, page in
                Button(page.title) { app.page = page }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .disabled(!app.onboarded)
            }
            Divider()
        }
        SidebarCommands()
        CommandGroup(before: .windowList) {
            // 关掉主窗口后从这里（或点程序坞图标）再打开。
            Button("UniPass Inkan Desktop") { openWindow(id: "main") }
                .keyboardShortcut("0")
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("UniPass Inkan Help") { NSWorkspace.shared.open(Display.readme) }
        }
        #if DEBUG
        DeveloperCommands(app: app)
        AttackDemoCommands(app: app)
        #endif
    }
}

/// 关于：版本、许可证、项目主页、第三方许可。
enum AboutPanel {
    static func show() {
        let body = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        func line(_ text: String, link: URL? = nil) {
            var a = attrs
            if let link { a[.link] = link }
            body.append(NSAttributedString(string: text, attributes: a))
            body.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        line(L("Coordinates signatures for a Safe with the offline UniPass Inkan Signer."))
        line("")
        line(L("Open source under the Apache License 2.0"))
        line("github.com/zhixianio/unipass-inkan", link: Display.repository)
        line(L("Third-party licenses"), link: Display.notice)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: L("UniPass Inkan Desktop"),
            .credits: body,
        ])
        NSApp.activate()
    }
}

/// 等宽、可选中的长文本（哈希、签名等）。值不翻译。
struct HexField: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
