#if DEBUG
import AppKit
import CoordinatorFlow
import SwiftUI
import UniPassCore

// 攻击演示（只在 DEBUG 构建里，docs/demo.md）：模拟被篡改的桌面端。
//
// 发送流程、确认页、签名面板和正常时一模一样（摘要句、指纹都是用户确认的那笔），只有发给签名器的请求被换掉。
// 只有带启动参数 `-InkanDemo YES` 时才启用：唯一的入口是讲解窗口（「窗口 › Attack Demo Presenter」，⌃⌥⌘D），
// 场景也在那里选；主窗口里什么都不显示（录屏只录主窗口，讲解窗口可以放在另一块屏幕上）。
// 文字都在 AttackDemo 字符串表里，Release 构建不带这个表（project.yml）。

@Observable
final class AttackDemoState {
    var scenario: AttackDemo?

    struct Sent {
        let scenario: AttackDemo
        let shown: SafeTxRequest
        let sent: SafeTxRequest
        let at: Date
    }

    /// 最近一次发给签名器的被篡改请求（给讲解窗口看）。
    var lastSent: Sent?

    func record(_ scenario: AttackDemo, shown: SafeTxRequest, sent: SafeTxRequest) {
        lastSent = Sent(scenario: scenario, shown: shown, sent: sent, at: .now)
    }

    static let windowID = "attack-demo"

    static func title(_ a: AttackDemo) -> LocalizedStringResource {
        switch a {
        case .bybit: LocalizedStringResource("Bybit-style", table: "AttackDemo")
        case .addressPoisoning: LocalizedStringResource("Address poisoning", table: "AttackDemo")
        case .refundDrain: LocalizedStringResource("Refund drain", table: "AttackDemo")
        }
    }

    static func description(_ a: AttackDemo) -> LocalizedStringResource {
        switch a {
        case .bybit:
            LocalizedStringResource("The signer receives a DELEGATECALL to an unknown contract (the one from the Bybit hack) whose call data looks like transfer(…, 0). Expected: refused outright, because a DELEGATECALL to a contract that isn't one of Safe's official libraries is never signed.", table: "AttackDemo")
        case .addressPoisoning:
            LocalizedStringResource("The recipient is replaced by an address with the same first and last 6 hex digits. Expected: red, rule R05, with both addresses shown side by side. The real recipient must be in the signer's address book.", table: "AttackDemo")
        case .refundDrain:
            LocalizedStringResource("The transfer itself is unchanged, but gasPrice, baseGas and refundReceiver make the Safe pay about 1 ETH to the attacker when executed. Expected: refused outright.", table: "AttackDemo")
        }
    }
}

/// 打开讲解窗口的菜单项（「窗口」菜单，⌃⌥⌘D）。只在 `-InkanDemo YES` 时出现。
///
/// 以前是挂在主窗口视图上的 ⌥⌘D 按键监听，有两个问题：⌥⌘D 是 macOS 自带的「程序坞自动隐藏」快捷键，系统先截走；
/// 监听挂在 RootView 的 Group 上，走完欢迎引导、视图换掉时会被删掉。菜单项不跟视图走，也总能用鼠标点。
struct AttackDemoCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if app.demoEnabled {
            CommandGroup(before: .windowList) {
                Button { openWindow(id: AttackDemoState.windowID) } label: {
                    Text("Attack Demo Presenter", tableName: "AttackDemo")
                }
                .keyboardShortcut("d", modifiers: [.command, .option, .control])
                Divider()
            }
        }
    }
}

/// 讲解窗口：当前场景、预期结果、实际发给签名器的是什么。
struct AttackDemoPresenterView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var state = app.attackDemo
        Form {
            Section {
                Picker(selection: $state.scenario) {
                    Text("Off", tableName: "AttackDemo").tag(AttackDemo?.none)
                    ForEach(AttackDemo.allCases, id: \.self) { Text(AttackDemoState.title($0)).tag(Optional($0)) }
                } label: {
                    Text("Scenario", tableName: "AttackDemo")
                }
                .pickerStyle(.segmented)
                if let scenario = state.scenario {
                    Text(AttackDemoState.description(scenario))
                } else {
                    Text("Off: requests go to the signer unchanged.", tableName: "AttackDemo").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Run a normal send. The desktop app keeps showing what you entered; only the request sent to the signer is replaced.", tableName: "AttackDemo")
            }
            if let sent = state.lastSent {
                Section {
                    LabeledContent { Text(AttackDemoState.title(sent.scenario)) } label: { Text("Scenario", tableName: "AttackDemo") }
                    LabeledContent { Text(verbatim: app.summary(sent.shown).sentence) } label: { Text("Shown on the desktop", tableName: "AttackDemo") }
                    LabeledContent { mono(HashDisplay.short(sent.shown.safeTxHash)) } label: { Text("Fingerprint shown", tableName: "AttackDemo") }
                    LabeledContent { mono(HashDisplay.short(sent.sent.safeTxHash)) } label: { Text("Fingerprint sent to the signer", tableName: "AttackDemo") }
                    LabeledContent { mono(sent.sent.tx.to.checksummed) } label: { Text(verbatim: "to") }
                    LabeledContent { mono(sent.sent.tx.operation == .call ? "CALL" : "DELEGATECALL") } label: { Text(verbatim: "operation") }
                    if !sent.sent.tx.gasPrice.isZero {
                        LabeledContent { mono("\(sent.sent.tx.gasPrice) / \(sent.sent.tx.baseGas) → \(sent.sent.tx.refundReceiver.checksummed)") } label: {
                            Text(verbatim: "gasPrice / baseGas → refundReceiver")
                        }
                    }
                } header: {
                    Text("Last request sent to the signer", tableName: "AttackDemo")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func mono(_ s: String) -> some View {
        Text(verbatim: s).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
}
#endif
