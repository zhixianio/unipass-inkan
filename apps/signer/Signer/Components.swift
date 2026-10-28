import SignerKit
import SwiftUI
import UniPassCore

// MARK: - 地址

/// 地址按固定 4 位分组显示（EIP-55 大小写不变），前后各 8 位（首尾各两组）加粗高亮；分组之间是空格，
/// 换行只发生在空格处，不会再出现 M0 里长十六进制被自动加连字符的问题。
struct AddressView: View {
    let info: AddressInfo
    /// 收款人 / 授权对象这类"对方"地址：不认识时标"首次出现"。命中 R05 的仿冒地址不要传 true（`RiskAssessment.isFirstSeen`）。
    var isCounterparty = false
    /// 命中 R05 时传入地址簿里那个相似地址：改为高亮**不同的字符**，而不是加粗首尾（首尾恰恰是伪造的部分）。
    var compareTo: Address? = nil
    /// 调用方自己标了来源（例如"本机"）时不显示来源标记。
    var hidesSource = false
    /// 不需要逐字核对的地方：名字 + 前后各 8 位的短地址。整段分组地址只用在要核对的地方
    /// （收款人等对方地址、新签名人、登记 Safe 时的签名人）。
    var compact = false
    /// 本机签名人地址不允许选中复制（它不能收款，见 `SignerAddressBlock`）。
    var selectable = true

    static func groups(_ a: Address) -> [String] {
        let hex = Array(a.checksummed.dropFirst(2))
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<min($0 + 4, hex.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let label = info.label {
                    Text(verbatim: Explanation.sanitize(label)).font(compact ? .body : .subheadline.weight(.semibold))
                }
                if !hidesSource { sourceBadge }
            }
            if compact {
                Text(verbatim: Explanation.shortAddress(info.address))
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                // 要核对的地址完整显示：只换行，不截断。
                if selectable {
                    groupedText.font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                } else {
                    groupedText.font(.system(.callout, design: .monospaced))
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var groupedText: Text {
        if let other = compareTo { return Self.diffText(info.address, against: other) }
        let g = Self.groups(info.address)
        var t = Text(verbatim: "0x ")
        for (i, part) in g.enumerated() {
            // 前后各 8 位：前两组和后两组。前后各 4 位的仿冒地址很容易算出来，8+8 算不出来。
            let emphasized = i < 2 || i >= g.count - 2
            t = t + Text(verbatim: part).fontWeight(emphasized ? .bold : .regular)
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            if i < g.count - 1 { t = t + Text(verbatim: " ") }
        }
        return t
    }

    /// 按 4 位分组显示 `a`，和 `b` 不同的字符红色加粗，相同的字符灰色。
    static func diffText(_ a: Address, against b: Address) -> Text {
        let ha = Array(a.checksummed.dropFirst(2)), hb = Array(b.checksummed.dropFirst(2))
        var t = Text(verbatim: "0x ")
        for i in ha.indices {
            let differs = ha[i].lowercased() != hb[i].lowercased()
            t = t + Text(verbatim: String(ha[i])).fontWeight(differs ? .heavy : .regular)
                .foregroundStyle(differs ? Color.red : Color.secondary)
            if i % 4 == 3, i < ha.count - 1 { t = t + Text(verbatim: " ") }
        }
        return t
    }

    @ViewBuilder var sourceBadge: some View {
        switch info.source {
        case .mySafe: Badge(text: String(localized: "My Safe"), color: .blue)
        case .addressBook: Badge(text: String(localized: "Address book"), color: .green)
        case .safeOwner: Badge(text: String(localized: "Safe signer"), color: .blue)
        case .thisSigner: Badge(text: String(localized: "This iPhone"), color: .blue)
        case .library(let kind): Badge(text: kind.isToken ? String(localized: "Known token") : String(localized: "Known contract"), color: .teal)
        case .unknown: if isCounterparty { Badge(text: String(localized: "First seen"), color: .orange) } else { Badge(text: String(localized: "Unknown"), color: .gray) }
        }
    }
}

extension LabelLibrary.Kind {
    var isToken: Bool { [.erc20, .erc721, .erc1155].contains(self) }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

/// 本机的签名人地址（signer proxy）：完整显示，标签旁常驻一个橙色小标"请勿转入资产"，不能复制。
/// 它只是 Safe 的签名人合约，没有提款功能，转进去的资产永久取不回（docs/rules.md "转给签名人地址"）。
/// 不用大面积红框：那样看起来像密钥出了问题。
struct SignerAddressBlock: View {
    let address: Address

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Signer address").font(.caption).foregroundStyle(.secondary)
                Badge(text: String(localized: "Don't send funds"), color: .orange)
            }
            AddressView(info: AddressInfo(address: address, label: nil, source: .unknown), hidesSource: true, selectable: false)
        }
    }
}

/// R05：投毒地址和它模仿的已知地址（地址簿 / 我的 Safe / Safe 的签名人 / 本机签名人地址）并排，不同的字符标红。
struct LookalikeComparison: View {
    let address: Address
    let similar: AddressInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Looks like an address you know, but is not the same", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.red)
            row(Text("This transaction"), AddressView.diffText(address, against: similar.address))
            row(knownTitle, AddressView.diffText(similar.address, against: address))
            Text("The characters in red are different. The beginning and the end match on purpose.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var knownTitle: Text {
        switch similar.source {
        case .safeOwner(let safe, let name):
            Text("Known: signer of the Safe \(name.map { Explanation.sanitize($0) } ?? Explanation.shortAddress(safe))")
        case .thisSigner:
            Text("Known: this iPhone's signer address")
        default:
            Text("Known: \(Explanation.sanitize(similar.label ?? ""))")
        }
    }

    private func row(_ title: Text, _ value: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption).foregroundStyle(.secondary)
            value.font(.system(.callout, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 联网明细

/// 联网检查逐项显示：Wi-Fi、蜂窝、数据线各一行（按接口地址判断）。蓝牙不读（读开关要链接 CoreBluetooth，签名器不带任何通信框架），一直单独提醒。
struct ConnectionChecklist: View {
    let status: NetworkStatus
    /// 首页和确认页上只列还连着的项（加上蓝牙提醒）；全部明细收在"详情"里。
    var onlyConnected = false
    var showsBluetooth = true

    var body: some View {
        let on = status.connections
        VStack(alignment: .leading, spacing: 6) {
            ForEach([ConnectionKind.wifi, .cellular, .cable], id: \.self) { k in
                if on.contains(k) {
                    row(k.connectedText, "xmark.circle.fill", .red)
                } else if !onlyConnected {
                    row(k.clearText, "checkmark.circle.fill", .green)
                }
            }
            if on.contains(.unknown) {
                row(String(localized: "The network state could not be read, so signing is refused."), "exclamationmark.circle.fill", .red)
            }
            if showsBluetooth {
                row(String(localized: "Bluetooth: the signer does not read its status, so that it carries no communication framework. Make sure it is off in Settings."), "questionmark.circle.fill", .orange)
            }
        }
        .font(.callout)
    }

    private func row(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}

extension ConnectionKind {
    var connectedText: String {
        switch self {
        case .wifi: String(localized: "Wi-Fi is connected: turn it off in Settings › Wi-Fi.")
        case .cellular: String(localized: "Cellular data is connected: turn on Airplane Mode in Settings.")
        case .cable: String(localized: "A cable or adapter is connected: unplug it.")
        case .unknown: ""
        }
    }

    var clearText: String {
        switch self {
        case .wifi: String(localized: "Wi-Fi: not connected")
        case .cellular: String(localized: "Cellular data: not connected")
        case .cable: String(localized: "Cable: not connected")
        case .unknown: ""
        }
    }
}

// MARK: - 风险等级

extension Verdict {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .rejected: .red
        }
    }

    var title: String {
        switch self {
        case .green: String(localized: "No issues found")
        case .yellow: String(localized: "Check carefully")
        case .red: String(localized: "High risk")
        case .rejected: String(localized: "Refused")
        }
    }

    var symbol: String {
        switch self {
        case .green: "checkmark.shield.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "exclamationmark.octagon.fill"
        case .rejected: "xmark.octagon.fill"
        }
    }
}

extension RiskLevel {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        }
    }
}

// MARK: - 哈希短码、链

enum Display {
    /// 交易指纹（safeTxHash 短码）：前 8 位 + 后 8 位，按 4 位分组。只显示，不要求和桌面端比对；
    /// 安全靠的是 Signer 自己对交易的白话说明。
    static func shortHash(_ h: Data) -> String {
        let hex = Array(h.hexString.dropFirst(2))
        guard hex.count >= 16 else { return String(hex) }
        let head = String(hex[0..<4]) + " " + String(hex[4..<8])
        let tail = String(hex[(hex.count - 8)..<(hex.count - 4)]) + " " + String(hex[(hex.count - 4)...])
        return head + " … " + tail
    }

    /// 完整的 safeTxHash，按 4 位分组（技术细节里用）。
    static func fullHash(_ h: Data) -> String {
        let hex = Array(h.hexString.dropFirst(2))
        return "0x " + stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<min($0 + 4, hex.count)]) }.joined(separator: " ")
    }

    /// 网络名，不显示 chainId；测试网标"测试网"。
    static func chain(_ id: UInt64) -> String {
        switch id {
        case 1: "Ethereum"
        case 8453: "Base"
        case 11_155_111: String(localized: "Sepolia (testnet)")
        default: String(localized: "Unsupported network")
        }
    }

    /// 所需同意人数，和桌面端同一个说法（不说"门限"）。
    static func approvals(_ threshold: UInt64?, of count: Int) -> String {
        guard let t = threshold else { return String(localized: "Required approvals unknown") }
        return String(localized: "Any \(Int(t)) of \(count) must approve")
    }

    /// 窄栏里用的短说法（改签名人的前后对比）。
    static func approvalsShort(_ threshold: UInt64?, of count: Int) -> String {
        guard let t = threshold else { return String(localized: "Required approvals unknown") }
        return String(localized: "\(Int(t)) of \(count) must approve")
    }

    static var language: Explanation.Language {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
}

// MARK: - 二维码

/// 单帧 UR 直接显示；多帧时每 0.2 秒换一帧（喷泉码，扫码端漏帧也没关系）。
struct URQRCode: View {
    let ur: UR
    var maxFragmentLen = 220
    @State private var encoder: UREncoder?
    @State private var part = ""

    var body: some View {
        VStack(spacing: 8) {
            if let image = QRCode.image(for: part.isEmpty ? ur.qrString : part.uppercased()) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 320).accessibilityLabel(Text("QR code"))
            }
            if let encoder, !encoder.isSinglePart {
                Text("Animated QR, \(encoder.seqLen) parts").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: ur) {
            var e = UREncoder(ur, maxFragmentLen: maxFragmentLen)
            encoder = e
            part = e.nextPart()
            guard !e.isSinglePart else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                part = e.nextPart()
            }
        }
    }
}
