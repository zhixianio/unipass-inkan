import SignerKit
import SwiftUI
import UniPassCore

/// 确认页 / 拒签页。只消费 RiskAssessment，不自己重新解析交易。
struct ConfirmView: View {
    let assessment: RiskAssessment
    let ur: UR
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var signing = false
    @State private var error: String?
    @State private var addingAddress: Address?

    private var lang: Explanation.Language { Display.language }
    private var verdict: Verdict { assessment.verdict }

    var body: some View {
        NavigationStack {
            List {
                header
                if verdict == .rejected {
                    rejectionSection
                }
                // "这笔交易做什么"放在最前面：安全靠的是这里的说明。网络、Safe 在后面，nonce、交易指纹收进"技术细节"。
                if let req = assessment.request {
                    actionsSection
                    ownerChangeSection(req)
                }
                if !assessment.findings.isEmpty { findingsSection }
                if let req = assessment.request { summarySection(req) }
                if verdict != .rejected { signSection }
            }
            // 签名按钮固定在屏幕下方；确认短语、联网提示和错误仍在列表里，紧挨着按钮上方。
            .safeAreaInset(edge: .bottom) {
                if verdict != .rejected { signButton }
            }
            .navigationTitle(verdict == .rejected ? Text("Refused") : Text("Review transaction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { model.route = nil } }
            }
            .sheet(item: Binding(get: { addingAddress.map(IdentifiedAddress.init) }, set: { addingAddress = $0?.address })) { item in
                AddToBookSheet(address: item.address) { label in
                    try await model.addToAddressBook(item.address, label: label, reassessing: ur)
                }
            }
        }
    }

    // MARK: 头部

    /// 结论：一行，带底色，不占半屏。
    private var header: some View {
        Section {
            Label { Text(verdict.title).font(.headline) } icon: { Image(systemName: verdict.symbol) }
                .foregroundStyle(verdict.color)
                .listRowBackground(verdict.color.opacity(0.12))
        }
    }

    private var rejectionSection: some View {
        Section {
            ForEach(Array(assessment.rejections.enumerated()), id: \.offset) { _, r in
                Label(r.explanation.render(lang), systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Text("This request cannot be signed. There is no way to override this.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Why it was refused")
        }
    }

    // MARK: 交易概要（F2）

    private func summarySection(_ req: SafeTxRequest) -> some View {
        Section {
            // Safe 只显示名字和短地址（它在"我的 Safe"里，加入时已核对过）；完整地址在技术细节里。
            LabeledContent("Safe") { AddressView(info: safeInfo(req), compact: true).multilineTextAlignment(.trailing) }
            LabeledContent("Network") { Text(verbatim: Display.chain(req.chainID)) }
            // 短码和桌面端签名面板的"交易指纹"同一写法。只显示，不要求比对：注意力放在上面"这笔交易做什么"。
            LabeledContent("Transaction fingerprint") {
                Text(verbatim: Display.shortHash(req.safeTxHash)).font(.system(.callout, design: .monospaced))
            }
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe address").font(.caption).foregroundStyle(.secondary)
                    AddressView(info: safeInfo(req), hidesSource: true)
                }
                LabeledContent("Nonce") { Text(verbatim: req.tx.nonce.description).monospaced() }
                // 不为 0 时规则判黄（R12）；退款字段不为空的请求已经硬拒，不会走到能签的页面。
                if !req.tx.safeTxGas.isZero {
                    LabeledContent("Execution gas (safeTxGas)") { Text(verbatim: req.tx.safeTxGas.description).monospaced() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full fingerprint (safeTxHash)").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: Display.fullHash(req.safeTxHash)).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Transaction")
        }
    }

    private func safeInfo(_ req: SafeTxRequest) -> AddressInfo {
        let s = model.store.mySafes.first { $0.chainID == req.chainID && $0.address == req.safe }
        return AddressInfo(address: req.safe, label: s?.name, source: s == nil ? .unknown : .mySafe)
    }

    // MARK: 动作

    private var actionsSection: some View {
        Section {
            ForEach(Array(assessment.actions.enumerated()), id: \.offset) { _, a in
                ActionRow(action: a, findings: assessment.findings.filter { $0.path == a.path }, language: lang,
                          thisSigner: model.identity?.signerProxy,
                          isFirstSeen: { [assessment, signer = model.identity?.signerProxy] in assessment.isFirstSeen($0, thisSigner: signer) }) { address in
                    addingAddress = address
                }
                .padding(.leading, CGFloat(a.path.count) * 14)
            }
        } header: {
            Text("What it does")
        }
    }

    // MARK: 改 owner（F4）

    @ViewBuilder
    private func ownerChangeSection(_ req: SafeTxRequest) -> some View {
        if let safe = model.store.mySafes.first(where: { $0.chainID == req.chainID && $0.address == req.safe }),
           let p = OwnerChangePreview(assessment, safe: safe, thisSigner: model.identity?.signerProxy) {
            Section {
                OwnerChangeView(preview: p, thisSigner: model.identity?.signerProxy)
            } header: {
                Text("Signers before and after")
            } footer: {
                Text("Based on the signers recorded when this Safe was added to this iPhone.")
            }
        }
    }

    private var findingsSection: some View {
        Section {
            // 每条说明以规则编号开头（core 的文字）：高风险时确认短语按编号要输入对应的字符。
            ForEach(Array(assessment.findings.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(f.level.color).frame(width: 10, height: 10).padding(.top, 5)
                    Text(f.explanation.render(lang)).font(.callout)
                }
            }
        } header: {
            Text("Risk checks")
        }
    }

    // MARK: 签名

    @ViewBuilder private var signSection: some View {
        Section {
            if verdict == .red {
                let tokens = ConfirmationPhrase(assessment).tokens
                Text("High risk. To continue, type the 4 characters asked for in each item below, separated by spaces.")
                    .font(.callout)
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in
                    Text(verbatim: "• " + tokenInstruction(t)).font(.callout)
                }
                TextField("e.g. 7242 9111", text: $phrase)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().font(.body.monospaced())
            }
            if !model.isOffline {
                Label("Online: cannot sign", systemImage: "wifi.exclamationmark").foregroundStyle(.red).fontWeight(.semibold)
                ConnectionChecklist(status: model.network, onlyConnected: true)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
    }

    private var signButton: some View {
        let needsPhrase = verdict == .red && !ConfirmationPhrase(assessment).matches(phrase)
        return VStack(spacing: 6) {
            // 按钮不可用时说明原因（按钮本身禁用后颜色很浅）。
            if !model.isOffline {
                Text("Disconnect from the network to sign.").font(.footnote).foregroundStyle(.red)
            } else if needsPhrase {
                Text("Type the characters asked for above to enable signing.").font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await sign() }
            } label: {
                Label(verdict == .red ? "Sign anyway with Face ID" : "Sign with Face ID", systemImage: "faceid")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(verdict == .red ? .red : .accentColor)
            .disabled(signing || !model.isOffline || needsPhrase)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    /// 说明要输入什么，不给出答案本身。
    private func tokenInstruction(_ t: ConfirmationPhrase.Token) -> String {
        switch t.kind {
        case .lastFour: String(localized: "\(t.rule.rawValue): the last 4 characters of the address it flags")
        case .number: String(localized: "\(t.rule.rawValue): the new number of required approvals")
        case .selector: String(localized: "\(t.rule.rawValue): the last 4 characters of the function code")
        case .firstDifference(_, _, let start): String(localized: "\(t.rule.rawValue): 4 characters starting at character \(start + 1) after 0x, where it first differs from the address you know (highlighted in red)")
        case .ruleID: String(localized: "Type the rule id \(t.rule.rawValue)")
        case .addressWindow(_, let start): String(localized: "\(t.rule.rawValue): 4 characters starting at character \(start + 1) after 0x of the address it flags")
        case .ruleNumber: String(localized: "Type \(t.expected)")
        }
    }

    private func sign() async {
        signing = true
        defer { signing = false }
        error = nil
        do {
            try await model.sign(assessment, confirmation: verdict == .red ? phrase : nil)
        } catch TransactionSigner.Failure.networkOnline {
            error = String(localized: "This iPhone went online while signing. Disconnect everything listed above, then try again.")
        } catch TransactionSigner.Failure.noKey {
            error = String(localized: "Create a signing key first.")
        } catch {
            if let p = model.policy, p.explainsInvalidation(error) {
                self.error = String(localized: "This key no longer works: Face ID enrollment changed after it was created. Ask the other signers to remove this iPhone from the Safe, then create a new key and pair again.")
            } else {
                self.error = "\(error)"
            }
        }
    }
}

struct IdentifiedAddress: Identifiable {
    let address: Address
    var id: String { address.checksummed }
}

/// 一条调用：operation、白话说明、目标、对方地址、金额和代币。
struct ActionRow: View {
    let action: ActionSummary
    let findings: [Finding]
    let language: Explanation.Language
    /// 本机签名人地址：作为收款方时标出来，不提供"加入地址簿"（这样的交易已被硬拒）。
    let thisSigner: Address?
    /// 对方地址要不要标"首次出现"并提供"加入地址簿"（`RiskAssessment.isFirstSeen`：命中 R05 的不提供）。
    let isFirstSeen: (AddressInfo) -> Bool
    let addToBook: (Address) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if action.operation == .delegateCall {
                if case .multiSend = action.kind {
                    Text(verbatim: "DELEGATECALL · MultiSend").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "DELEGATECALL").font(.title.weight(.heavy)).foregroundStyle(.red)
                }
            }
            // 简单转账只显示大号金额和收款人；说明句和它们重复。其它调用保留说明句。
            if isSimpleTransfer {
                HStack(spacing: 6) {
                    Circle().fill(action.level.color).frame(width: 10, height: 10)
                    Text("Send").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .top) {
                    Circle().fill(action.level.color).frame(width: 10, height: 10).padding(.top, 6)
                    Text(action.explanation.render(language)).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            details
            ForEach(Array(lookalikes.enumerated()), id: \.offset) { _, l in
                LookalikeComparison(address: l.0, similar: l.1)
            }
        }
        .padding(.vertical, 4)
    }

    /// 本条调用里命中 R05 的 (地址, 相似的已知地址)。
    private var lookalikes: [(Address, AddressInfo)] {
        findings.compactMap { f in
            guard case .lookalike(let a, let similar)? = f.subject else { return nil }
            return (a, knownInfo(similar))
        }
    }

    /// 相似地址的标签：从 R05 说明的第二个参数里取（规则层已经解析过来源）。
    private func knownInfo(_ a: Address) -> AddressInfo {
        for f in findings where f.rule == .R05 {
            for arg in f.explanation.args {
                if case .address(let info) = arg, info.address == a { return info }
            }
        }
        return AddressInfo(address: a, label: nil, source: .addressBook)
    }

    @ViewBuilder private var details: some View {
        switch action.kind {
        case .nativeTransfer(let to, let amount):
            amountRow(amount, token: nil)
            counterparty(String(localized: "To"), to)
        case .tokenTransfer(let token, let from, let to, let amount):
            amountRow(amount, token: token)
            if !token.known { labeled(String(localized: "Token contract"), info(token)) }
            if let from { labeled(String(localized: "From"), from) }
            counterparty(String(localized: "To"), to)
        case .nftTransfer(let collection, let from, let to, let id, _):
            LabeledContent("Item") { Text(verbatim: "#\(id)").monospaced() }
            labeled(String(localized: "Collection"), info(collection))
            labeled(String(localized: "From"), from)
            counterparty(String(localized: "To"), to)
        case .nftBatchTransfer(let collection, let from, let to, let ids, let amounts):
            ForEach(Array(zip(ids, amounts).enumerated()), id: \.offset) { _, item in
                LabeledContent("Item") { Text(verbatim: "#\(item.0) × \(item.1)").monospaced() }
            }
            labeled(String(localized: "Collection"), info(collection))
            labeled(String(localized: "From"), from)
            counterparty(String(localized: "To"), to)
        case .unknownTransferFrom(let c, let from, let to, _):
            labeled(String(localized: "Contract"), info(c))
            labeled(String(localized: "From"), from)
            counterparty(String(localized: "To"), to)
        case .approval(let token, let spender, let amount, let unlimited):
            if unlimited { Text("Unlimited").font(.headline).foregroundStyle(.red) } else { amountRow(amount, token: token) }
            labeled(String(localized: "Token"), info(token))
            counterparty(String(localized: "Spender"), spender)
        case .allowanceChange(let token, let spender, let delta, _, let unlimited):
            if unlimited { Text("Unlimited").font(.headline).foregroundStyle(.red) } else { amountRow(delta, token: token) }
            counterparty(String(localized: "Spender"), spender)
        case .approvalForAll(let c, let op, _):
            labeled(String(localized: "Collection"), info(c))
            counterparty(String(localized: "Operator"), op)
        case .permit2Approval(let token, let spender, let amount, _, let unlimited):
            if unlimited { Text("Unlimited").font(.headline).foregroundStyle(.red) } else { amountRow(amount, token: token) }
            counterparty(String(localized: "Spender"), spender)
        case .safeConfig, .multiSend, .emptyCall, .invalid:
            labeled(String(localized: "Target"), action.target)
        case .contractCall(let target, _):
            labeled(String(localized: "Contract"), target)
        }
        if let v = action.nativeValue, !isNative {
            amountRow(v, token: nil)
        }
    }

    private var isNative: Bool { if case .nativeTransfer = action.kind { true } else { false } }

    /// 顶层的普通 CALL：转 ETH，或者从 Safe 自己转出代币（transfer，没有 from）。
    private var isSimpleTransfer: Bool {
        guard action.operation == .call, action.path.isEmpty else { return false }
        switch action.kind {
        case .nativeTransfer: return true
        case .tokenTransfer(_, let from, _, _): return from == nil
        default: return false
        }
    }

    private func info(_ t: TokenInfo) -> AddressInfo {
        AddressInfo(address: t.address, label: t.symbol ?? t.name, source: t.known ? .library(t.kind ?? .erc20) : .unknown)
    }

    private func amountRow(_ amount: TokenAmount, token: TokenInfo?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: amountText(amount)).font(.title3.weight(.semibold).monospacedDigit())
            if let token, !token.known {
                Text("Token contract not in the built-in library").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func amountText(_ amount: TokenAmount) -> String {
        amount.formatted + " " + (amount.decimals == nil ? String(localized: "raw units") + " " : "") + (amount.symbol.map { Explanation.sanitize($0) } ?? "")
    }

    /// 不是收款人这类"对方"的地址（目标合约、代币、集合、From）：名字 + 短地址。
    private func labeled(_ title: String, _ info: AddressInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            AddressView(info: info, compact: true)
        }
    }

    private func counterparty(_ title: String, _ info: AddressInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if info.address == thisSigner {
                Badge(text: String(localized: "This iPhone's signer address"), color: .red)
                AddressView(info: info, hidesSource: true)
            } else {
                let firstSeen = isFirstSeen(info)
                // 不认识又不算首次出现的，就是命中 R05 的仿冒地址：不标来源，下面的并排对比已经说明。
                AddressView(info: info, isCounterparty: firstSeen, compareTo: lookalikes.first { $0.0 == info.address }?.1.address,
                            hidesSource: !info.isKnown && !firstSeen)
            }
            if isFirstSeen(info) {
                Button {
                    addToBook(info.address)
                } label: {
                    Label("Add to address book", systemImage: "person.crop.circle.badge.plus").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct OwnerChangeView: View {
    let preview: OwnerChangePreview
    let thisSigner: Address?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                column(String(localized: "Before"), preview.beforeOwners, preview.beforeThreshold, highlight: Set(preview.removed), color: .red)
                column(String(localized: "After"), preview.afterOwners, preview.afterThreshold, highlight: Set(preview.added), color: .green)
            }
            ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, w in
                Label(text(w), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
    }

    private func column(_ title: String, _ owners: [Address], _ threshold: UInt64?, highlight: Set<Address>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(Display.approvalsShort(threshold, of: owners.count)).font(.headline)
            ForEach(owners, id: \.self) { o in
                HStack(spacing: 4) {
                    Text(verbatim: Explanation.shortAddress(o)).font(.caption.monospaced())
                        .foregroundStyle(highlight.contains(o) ? color : .primary)
                        .fontWeight(highlight.contains(o) ? .bold : .regular)
                    if o == thisSigner { Badge(text: String(localized: "This iPhone"), color: .blue) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(_ w: OwnerChangePreview.Warning) -> String {
        switch w {
        case .thresholdExceedsOwners: String(localized: "The required approvals are more than the number of signers; the transaction will fail.")
        case .thresholdEqualsOwners: String(localized: "Every signer must approve. Losing any single key locks the Safe for good.")
        case .singleSignature: String(localized: "Any single signer will be able to move funds alone.")
        case .removesThisSigner: String(localized: "This iPhone will no longer be a signer.")
        case .ownerNotInRecord(let a): String(localized: "Signer \(Explanation.shortAddress(a)) is not in this iPhone's record. The record may be outdated, or the transaction will fail.")
        }
    }
}

struct AddToBookSheet: View {
    let address: Address
    let save: (String) async throws -> Void
    @Environment(AppModel.self) private var model
    @State private var label = ""
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool { !trimmed.isEmpty && model.store.isNameTaken(trimmed) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AddressView(info: AddressInfo(address: address, label: nil, source: .unknown), isCounterparty: true)
                    Text("Compare every group with the address you expect, not just the first and last characters. Address poisoning copies those.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Name", text: $label)
                    if nameTaken {
                        Text("A Safe or an address book entry already has this name. Use a different one.").foregroundStyle(.red)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Saving asks for Face ID.")
                }
            }
            .navigationTitle("Add to address book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        error = nil
                        Task {
                            defer { saving = false }
                            do {
                                try await save(trimmed)
                                dismiss()
                            } catch {
                                if !AppModel.isCancellation(error) { self.error = AppModel.describe(error) }
                            }
                        }
                    }
                    .disabled(trimmed.isEmpty || nameTaken || saving)
                }
            }
        }
    }
}
