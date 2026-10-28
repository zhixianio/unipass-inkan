import Foundation

/// L1 规则引擎。规则说明见 docs/rules.md。
public struct RiskEngine: Sendable {
    public let context: RiskContext

    public init(context: RiskContext) {
        self.context = context
    }

    // MARK: 常量

    /// R03：授权数量多大就当作"无限"（安全核查 P1-2）。按原始整数定（旧阈值 2^128）不行：对 6 位小数的 USDC，
    /// 2^128−1 是 3.4×10^32 个，远超任何供应量，实际就是无限。
    /// - 有 decimals（库里的 ERC-20）：≥ 10^(decimals+9)，即 10 亿个代币。没有正常的授权会到这个量级。
    /// - 没有 decimals（不在库里的代币）：≥ 2^96（18 位小数时约 790 亿个）。无限授权常见的写法（2^256−1、2^255、2^160−1、2^128−1）都在其上。
    public static let unlimitedTokenUnitsExponent = 9
    public static let unlimitedThresholdWithoutDecimals = UInt256(words: [0, 1 << 32, 0, 0])

    public static func isUnlimited(_ raw: UInt256, decimals: Int?) -> Bool {
        guard let d = decimals, d >= 0, d + unlimitedTokenUnitsExponent <= 77 else { return raw >= unlimitedThresholdWithoutDecimals }
        var threshold = UInt256(1)
        for _ in 0..<(d + unlimitedTokenUnitsExponent) { threshold = threshold.multipliedAdding(10, 0)! }
        return raw >= threshold
    }

    /// R05：和已知地址（地址簿、我的 Safe、本机签名人地址、已登记 Safe 的签名人）**开头相同的位数 + 结尾相同的位数 ≥ 6**
    ///（十六进制，不区分大小写，怎么分都算：3+3、2+8、8+2、6+0……）但地址不同，就判红。
    /// 依据：钱包和浏览器缩写地址时显示前后 4–8 位，地址投毒就是生成这几位相同的地址；只仿一端（例如后 8 位，
    /// 正是地址显示时加粗的部分）也要抓到。两个无关地址碰巧满足的概率约 7×16^-6 ≈ 4×10^-7，
    /// 已知地址 1000 个时每笔交易误报约 4×10^-4，可以接受。
    public static let lookalikeMatchChars = 6

    // MARK: 入口

    /// 从签名请求开始：请求解析失败、裸哈希、不是 SafeTx 都硬拒。
    public func assess(signRequest req: EthSignRequest) -> RiskAssessment {
        do {
            var a = assess(try SafeTxRequest(signRequest: req))
            a.requestID = req.requestID
            if let id = context.signer, !Self.targets(req, id) {
                a.rejections.append(Rejection(reason: .notForThisSigner, explanation: Self.explain(.notForThisSigner)))
            }
            return a
        } catch let e as SafeTxRequest.ParseError {
            let reason: RejectionReason
            switch e {
            case .notTypedData:
                reason = req.dataType == .personalMessage && req.signData.count == 32 ? .rawHash : .unsupportedRequest(req.dataType)
            default:
                reason = .malformedRequest("\(e)")
            }
            return rejectedOnly(reason)
        } catch {
            return rejectedOnly(.malformedRequest("\(error)"))
        }
    }

    /// 从 UR 开始（类型必须是 eth-sign-request）。
    public func assess(ur: UR) -> RiskAssessment {
        do { return assess(signRequest: try EthSignRequest(ur: ur)) } catch {
            return rejectedOnly(.malformedRequest("\(error)"))
        }
    }

    public func assess(_ request: SafeTxRequest) -> RiskAssessment {
        let decoded = DecodedSafeTx(request)
        var state = State(request: request)

        if context.networkOnline { state.reject(.networkOnline) }
        if !SafeDeployments.supportedChains.contains(request.chainID) {
            state.reject(.unsupportedChain(request.chainID))
        } else if !context.mySafes.contains(where: { $0.chainID == request.chainID && $0.address == request.safe }) {
            state.reject(.safeNotRegistered(chainID: request.chainID, safe: request.safe))
        }

        // 退款字段（docs/rules.md "gas 与退款"）。Safe 1.3.0 / 1.4.1 / 1.5.0 的 execTransaction 一样：
        // gasPrice > 0 时按 (gasUsed + baseGas) × gasPrice 用 gasToken（零地址 = ETH）付给 refundReceiver（零地址 = tx.origin）。
        // gasPrice 为 0 时不付款，但其它三个字段不为空也一律拒绝：v1 不用退款，没有理由带着它们签名。
        let tx = request.tx
        if !tx.gasPrice.isZero || !tx.baseGas.isZero || tx.gasToken != .zero || tx.refundReceiver != .zero {
            state.reject(.gasRefundNotSupported(gasPrice: tx.gasPrice, baseGas: tx.baseGas,
                                                gasToken: tx.gasToken, refundReceiver: tx.refundReceiver))
        }

        visit(decoded.call, path: [], state: &state)

        // R12：safeTxGas 不为 0 时，内部调用失败不会让 execTransaction 回滚（GS013 只在 safeTxGas == 0 且 gasPrice == 0 时要求成功），
        // 交易照样记为已执行、nonce 被用掉。拿到签名的人可以故意给不够的 gas 让它失败。不会多转走钱，但这笔交易可能"白签"。
        if !tx.safeTxGas.isZero {
            state.findings.append(Finding(rule: .R12, level: .yellow, path: [],
                                          explanation: Explanation("rule.R12", .plain(tx.safeTxGas.description))))
        }
        return RiskAssessment(request: request, actions: state.actions, findings: state.findings, rejections: state.rejections)
    }

    /// derivation-path 必须是 `{1: [], 2: 这台 Signer 的指纹}`；带了 address 就必须是这台 Signer 的 proxy。
    static func targets(_ req: EthSignRequest, _ id: SignerIdentity) -> Bool {
        req.derivationPath.components.isEmpty && req.derivationPath.sourceFingerprint == id.keyFingerprint
            && (req.address == nil || req.address == id.signerProxy)
    }

    private func rejectedOnly(_ reason: RejectionReason) -> RiskAssessment {
        RiskAssessment(request: nil, actions: [], findings: [],
                       rejections: [Rejection(reason: reason, explanation: Self.explain(reason))])
    }

    // MARK: 遍历

    struct State {
        let request: SafeTxRequest
        var actions: [ActionSummary] = []
        var findings: [Finding] = []
        var rejections: [Rejection] = []

        mutating func reject(_ reason: RejectionReason) {
            rejections.append(Rejection(reason: reason, explanation: RiskEngine.explain(reason)))
        }
    }

    private func visit(_ call: DecodedCall, path: [Int], state: inout State) {
        let chain = state.request.chainID
        let target = info(call.to, chain: chain, safe: state.request.safe)
        var local: [Finding] = []
        func add(_ rule: RuleID, _ level: RiskLevel, _ e: Explanation, _ subject: Finding.Subject? = nil) {
            local.append(Finding(rule: rule, level: level, path: path, explanation: e, subject: subject))
        }
        let native = call.value.isZero ? nil : TokenAmount(raw: call.value, decimals: 18, symbol: "ETH")

        // DELEGATECALL：官方 MultiSend / MultiSendCallOnly 照常；官方升级 / 部署库判 R01 红（可越过）；其它一律硬拒。
        if call.operation == .delegateCall, SafeDeployments.multiSend(chainID: chain, address: call.to) == nil {
            if SafeDeployments.delegateCallLibraries.contains(call.to) {
                add(.R01, .red, Explanation("rule.R01", .address(target)), .address(call.to))
            } else if !state.rejections.contains(where: { $0.reason == .delegateCallNotAllowed(call.to) }) {
                state.reject(.delegateCallNotAllowed(call.to))
            }
        }

        let kind: ActionKind
        var explanation: Explanation
        switch call.action {
        case .plain:
            if let native {
                kind = .nativeTransfer(to: target, amount: native)
                explanation = Explanation("action.nativeTransfer", .amount(native), .address(target))
                counterparty(target, path: path, chain: chain, into: &local)
            } else {
                kind = .emptyCall(target)
                explanation = Explanation("action.emptyCall", .address(target))
            }

        case .invalid(let problem):
            kind = .invalid(problem)
            explanation = Explanation("action.invalid")
            state.reject(.decoding(problem, path: path))

        case .unknown(let selector):
            let sel = Explanation.Arg.plain(selector?.hexString ?? "—")
            if call.to == state.request.safe {
                kind = .safeConfig(.otherSelfCall(selector: selector))
                explanation = Explanation("action.safeOtherSelfCall", sel)
                add(.R02, .red, Explanation("rule.R02.selfCall", sel), .selector(selector.map { String($0.hexString.dropFirst(2)) } ?? ""))
            } else {
                kind = .contractCall(target: target, selector: selector)
                explanation = Explanation("action.contractCall", .address(target), sel)
                if context.labels.lookup(chainID: chain, address: call.to)?.isToken == true {
                    // 库里的代币合约上不认识的函数：可能是没解码的别名函数（另一种转账或授权写法），判红。
                    add(.R07, .red, Explanation("rule.R07.token", sel, .address(target)),
                        .selector(selector.map { String($0.hexString.dropFirst(2)) } ?? ""))
                } else {
                    add(.R07, .yellow, Explanation("rule.R07", sel, .address(target)))
                }
            }
            if native != nil { counterparty(target, path: path, chain: chain, into: &local) }

        case .multiSend(let contract, let inner):
            kind = .multiSend(contract, count: inner.count)
            explanation = Explanation("action.multiSend", .plain(String(inner.count)))

        case .known(let k):
            (kind, explanation) = known(k, call: call, target: target, chain: chain, safe: state.request.safe,
                                        path: path, findings: &local)
        }

        // R02（嵌套 Safe，安全核查 P2-3）：调用"我的 Safe"里任何一个 Safe 的函数（包括这个 Safe 自己的 approve 之类），
        // 或者用 Safe 的管理 / 执行类函数调用任何地址。单纯转 ETH 不算。execTransaction 的内层不解码，一律判红。
        if !call.data.isEmpty, !local.contains(where: { $0.rule == .R02 }) {
            let sel = call.data.count >= 4 ? Data(call.data.prefix(4)) : nil
            let selArg = Explanation.Arg.plain(sel?.hexString ?? "—")
            if context.mySafes.contains(where: { $0.address == call.to }) {
                add(.R02, .red, Explanation("rule.R02.mySafeCall", selArg, .address(target)), .address(call.to))
            } else if let sel, Selectors.safeManagement.contains(sel) {
                add(.R02, .red, Explanation("rule.R02.safeFunction", selArg, .address(target)), .selector(String(sel.hexString.dropFirst(2))))
            }
        }

        if native != nil, case .known = call.action {
            // 调用合约函数时顺带转原生币：收款方就是被调用的合约。
            counterparty(target, path: path, chain: chain, into: &local)
        }
        // DELEGATECALL 到 MultiSend 以外的地址：说明它真正的含义，调用数据"表面上"的解释放在里面。
        if call.operation == .delegateCall, SafeDeployments.multiSend(chainID: chain, address: call.to) == nil {
            explanation = Explanation("action.delegateCall", .address(target), .nested(explanation))
        }

        // 对方是 Safe 基础合约或 Permit2（ERC-20 approve 给 Permit2 除外）：硬拒（docs/rules.md "对方是 Safe 基础合约"）。
        for a in Self.counterparties(kind, target: native == nil ? nil : target) where isSafeContract(a.address, chain: chain)
            && !Self.approvesPermit2(kind, a.address)
            && !state.rejections.contains(where: { $0.reason == .counterpartyIsSafeContract(a.address) }) {
            state.reject(.counterpartyIsSafeContract(a.address))
        }

        // 收款方是这台 Signer 自己的签名人合约：硬拒（docs/rules.md "转给签名人地址"）。
        if let me = context.signer?.signerProxy, Self.sends(call: call, kind: kind, to: me),
           !state.rejections.contains(where: { $0.reason == .sendsToSignerAddress }) {
            state.reject(.sendsToSignerAddress)
        }

        let index = state.actions.count
        state.actions.append(ActionSummary(path: path, operation: call.operation, target: target, nativeValue: native,
                                           kind: kind, explanation: explanation,
                                           level: local.map(\.level).max() ?? .green))
        state.findings += local

        if case .multiSend(_, let inner) = call.action {
            let before = state.findings.count
            for (i, c) in inner.enumerated() { visit(c, path: path + [i], state: &state) }
            // R08：子调用命中 R01–R05 时，MultiSend 本身取其中最高级。
            let hits = state.findings[before...].filter { [.R01, .R02, .R03, .R05].contains($0.rule) }
            if let level = hits.map(\.level).max() {
                state.findings.insert(Finding(rule: .R08, level: level, path: path,
                                              explanation: Explanation("rule.R08", .plain(hits.map(\.rule.rawValue).uniqued().joined(separator: ", ")))),
                                      at: before)
                state.actions[index].level = max(state.actions[index].level, level)
            }
        }
    }

    /// 这条调用的对方：收款人、授权对象（增加授权时）、operator（授权时）、新 owner；带原生币时还有被调用的合约 `target`。
    static func counterparties(_ kind: ActionKind, target: AddressInfo?) -> [AddressInfo] {
        var out: [AddressInfo] = target.map { [$0] } ?? []
        switch kind {
        case .nativeTransfer(let to, _), .tokenTransfer(_, _, let to, _), .nftTransfer(_, _, let to, _, _), .unknownTransferFrom(_, _, let to, _),
             .nftBatchTransfer(_, _, let to, _, _):
            out.append(to)
        case .approval(_, let s, let amount, _), .permit2Approval(_, let s, let amount, _, _):
            if !amount.raw.isZero { out.append(s) }
        case .allowanceChange(_, let s, _, let increase, _):
            if increase { out.append(s) }
        case .approvalForAll(_, let o, let approved):
            if approved { out.append(o) }
        case .safeConfig(.addOwner(let o, _)), .safeConfig(.swapOwner(_, let o)):
            out.append(o)
        default: break
        }
        return out
    }

    /// ERC-20 `approve` / `increaseAllowance` 给 Permit2：这是 Permit2 的正常用法，Permit2 只在这时算认识的对方。
    static func approvesPermit2(_ kind: ActionKind, _ a: Address) -> Bool {
        guard a == SafeDeployments.permit2 else { return false }
        switch kind {
        case .approval(_, let s, _, _), .allowanceChange(_, let s, _, true, _): return s.address == a
        default: return false
        }
    }

    /// Safe 基础合约（singleton、proxy factory、fallback handler、库合约、WebAuthn signer factory）和 Permit2。
    func isSafeContract(_ a: Address, chain: UInt64) -> Bool {
        if a == SafeDeployments.permit2 || a == SafeDeployments.webAuthnSignerFactory { return true }
        if SafeDeployments.multiSendContracts.contains(where: { $0.address == a }) { return true }
        if SafeAddress.initCodes.contains(where: { $0.factory == a || $0.singleton == a }) { return true }
        if SafeAddress.compatibilityFallbackHandlers.values.contains(where: { $0.contains(a) }) { return true }
        guard let l = context.labels.lookup(chainID: chain, address: a) else { return false }
        return [.safeSingleton, .safeProxyFactory, .safeFallbackHandler, .safeLibrary, .permit2].contains(l.kind)
    }

    /// 这条调用会不会把资产转给 `a`：随调用转出 ETH 且被调用的就是它，或者代币 / NFT 的收款方是它。
    static func sends(call: DecodedCall, kind: ActionKind, to a: Address) -> Bool {
        if !call.value.isZero, call.to == a { return true }
        switch kind {
        case .tokenTransfer(_, _, let to, _), .nftTransfer(_, _, let to, _, _), .unknownTransferFrom(_, _, let to, _),
             .nftBatchTransfer(_, _, let to, _, _):
            return to.address == a
        default:
            return false
        }
    }

    // MARK: 已识别的函数

    private func known(_ k: KnownCall, call: DecodedCall, target: AddressInfo, chain: UInt64, safe: Address, path: [Int],
                       findings: inout [Finding]) -> (ActionKind, Explanation) {
        func add(_ rule: RuleID, _ level: RiskLevel, _ e: Explanation, _ subject: Finding.Subject? = nil) {
            findings.append(Finding(rule: rule, level: level, path: path, explanation: e, subject: subject))
        }
        func addr(_ a: Address) -> AddressInfo { info(a, chain: chain, safe: safe) }
        let token = tokenInfo(call.to, chain: chain)
        func amount(_ raw: UInt256) -> TokenAmount {
            TokenAmount(raw: raw, decimals: token.kind == .erc20 ? token.decimals : nil, symbol: token.symbol)
        }
        func checkToken(expected: Set<LabelLibrary.Kind>) {
            // R09：代币合约不在库里 → 黄；地址簿把这个陌生合约叫作库里某个代币的名字 → 红（同名不同地址）。
            if token.known, let kind = token.kind, expected.contains(kind) { return }
            if let book = bookEntry(call.to, chain: chain),
               let real = context.labels.tokens(chainID: chain, named: book.label).first(where: { $0.parsedAddress != call.to }) {
                add(.R09, .red, Explanation("rule.R09.nameClash", .text(book.label), .address(target),
                                            .address(AddressInfo(address: real.parsedAddress!, label: real.symbol ?? real.name,
                                                                 source: .library(real.kind)))), .address(call.to))
            } else {
                add(.R09, .yellow, Explanation("rule.R09.unknownToken", .address(target)))
            }
        }
        func safeChange(_ c: SafeConfigChange, _ e: Explanation) -> (ActionKind, Explanation) {
            let subject: Finding.Subject? = switch c {
            case .addOwner(let a, _), .removeOwner(let a, _), .enableModule(let a), .disableModule(let a),
                 .setGuard(let a), .setModuleGuard(let a), .setFallbackHandler(let a): .address(a.address)
            case .swapOwner(_, let new): .address(new.address)
            case .changeThreshold(let t): .number(t.description)
            case .otherSelfCall(let sel): .selector(sel.map { String($0.hexString.dropFirst(2)) } ?? "")
            }
            add(.R02, .red, Explanation("rule.R02"), subject)
            return (.safeConfig(c), e)
        }

        switch k {
        case .erc20Transfer(let to, let raw):
            checkToken(expected: [.erc20])
            let r = addr(to)
            counterparty(r, path: path, chain: chain, token: call.to, into: &findings)
            return (.tokenTransfer(token: token, from: nil, to: r, amount: amount(raw)),
                    Explanation("action.tokenTransfer", .amount(amount(raw)), .address(r), .address(target)))

        case .transferFrom(let from, let to, let value):
            let f = addr(from), r = addr(to)
            counterparty(r, path: path, chain: chain, token: call.to, into: &findings)
            switch token.kind {
            case .erc20? where token.known:
                return (.tokenTransfer(token: token, from: f, to: r, amount: amount(value)),
                        Explanation("action.tokenTransferFrom", .amount(amount(value)), .address(f), .address(r), .address(target)))
            case .erc721? where token.known:
                return (.nftTransfer(collection: token, from: f, to: r, tokenID: value, amount: nil),
                        Explanation("action.nftTransfer", .address(target), .plain(value.description), .address(f), .address(r)))
            default:
                // 不认识的合约：不解释成数量（parent 核对意见 3）。
                checkToken(expected: [.erc20, .erc721])
                return (.unknownTransferFrom(contract: token, from: f, to: r, value: value),
                        Explanation("action.unknownTransferFrom", .address(target), .address(f), .address(r), .plain(value.description)))
            }

        case .erc20Approve(let spender, let raw), .increaseAllowance(let spender, let raw), .decreaseAllowance(let spender, let raw):
            checkToken(expected: [.erc20])
            let s = addr(spender)
            let unlimited = Self.isUnlimited(raw, decimals: amount(raw).decimals)
            var isDecrease = false
            if case .decreaseAllowance = k { isDecrease = true }
            if unlimited, !isDecrease {
                add(.R03, .red, Explanation("rule.R03.unlimited", .address(s), .address(target)), .address(spender))
            }
            if !raw.isZero, !isDecrease { counterparty(s, path: path, chain: chain, token: call.to, into: &findings) }
            if case .erc20Approve = k {
                let e = raw.isZero ? Explanation("action.revoke", .address(target), .address(s))
                    : unlimited ? Explanation("action.approveUnlimited", .address(target), .address(s))
                    : Explanation("action.approve", .address(s), .amount(amount(raw)))
                return (.approval(token: token, spender: s, amount: amount(raw), unlimited: unlimited), e)
            }
            let e = Explanation(isDecrease ? "action.decreaseAllowance" : (unlimited ? "action.increaseAllowanceUnlimited" : "action.increaseAllowance"),
                                .address(s), .amount(amount(raw)))
            return (.allowanceChange(token: token, spender: s, delta: amount(raw), increase: !isDecrease, unlimited: unlimited), e)

        case .setApprovalForAll(let op, let approved):
            checkToken(expected: [.erc721, .erc1155])
            let o = addr(op)
            if approved {
                add(.R03, .red, Explanation("rule.R03.forAll", .address(o), .address(target)), .address(op))
                counterparty(o, path: path, chain: chain, token: call.to, into: &findings)
            }
            return (.approvalForAll(collection: token, operator: o, approved: approved),
                    Explanation(approved ? "action.approvalForAll" : "action.revokeForAll", .address(o), .address(target)))

        case .erc721SafeTransferFrom(let from, let to, let id, _):
            checkToken(expected: [.erc721])
            let f = addr(from), r = addr(to)
            counterparty(r, path: path, chain: chain, token: call.to, into: &findings)
            return (.nftTransfer(collection: token, from: f, to: r, tokenID: id, amount: nil),
                    Explanation("action.nftTransfer", .address(target), .plain(id.description), .address(f), .address(r)))

        case .erc1155SafeTransferFrom(let from, let to, let id, let n, _):
            checkToken(expected: [.erc1155])
            let f = addr(from), r = addr(to)
            counterparty(r, path: path, chain: chain, token: call.to, into: &findings)
            return (.nftTransfer(collection: token, from: f, to: r, tokenID: id, amount: n),
                    Explanation("action.nft1155Transfer", .plain(n.description), .address(target), .plain(id.description), .address(f), .address(r)))

        case .erc1155SafeBatchTransferFrom(let from, let to, let ids, let amounts, _):
            checkToken(expected: [.erc1155])
            let f = addr(from), r = addr(to)
            counterparty(r, path: path, chain: chain, token: call.to, into: &findings)
            let list = zip(ids, amounts).map { "#\($0) × \($1)" }.joined(separator: ", ")
            return (.nftBatchTransfer(collection: token, from: f, to: r, ids: ids, amounts: amounts),
                    Explanation("action.nftBatchTransfer", .plain(String(ids.count)), .address(target), .plain(list), .address(f), .address(r)))

        case .erc20Pull(let from, let raw):
            checkToken(expected: [.erc20])
            let f = addr(from), r = addr(safe)
            return (.tokenTransfer(token: token, from: f, to: r, amount: amount(raw)),
                    Explanation("action.tokenTransferFrom", .amount(amount(raw)), .address(f), .address(r), .address(target)))

        case .transferShares(let from, let to, let shares):
            checkToken(expected: [.erc20])
            let f = from.map(addr), r = addr(to)
            counterparty(r, path: path, chain: chain, token: call.to, into: &findings)
            // 份额不是代币数量，不按 decimals 换算。
            let amt = TokenAmount(raw: shares, decimals: nil, symbol: token.symbol)
            return (.tokenTransfer(token: token, from: f, to: r, amount: amt),
                    Explanation("action.transferShares", .plain(shares.description), .address(target), .address(r)))

        case .permit2Approve(let tokenAddress, let spender, let raw, let expiration):
            let t = tokenInfo(tokenAddress, chain: chain)
            let s = addr(spender)
            let amt = TokenAmount(raw: raw, decimals: t.kind == .erc20 ? t.decimals : nil, symbol: t.symbol)
            let unlimited = Self.isUnlimited(raw, decimals: amt.decimals)
            if unlimited { add(.R03, .red, Explanation("rule.R03.unlimited", .address(s), .address(addr(tokenAddress))), .address(spender)) }
            if !(t.known && t.kind == .erc20) { add(.R09, .yellow, Explanation("rule.R09.unknownToken", .address(addr(tokenAddress)))) }
            if !raw.isZero { counterparty(s, path: path, chain: chain, token: tokenAddress, into: &findings) }
            return (.permit2Approval(token: t, spender: s, amount: amt, expiration: expiration, unlimited: unlimited),
                    Explanation(unlimited ? "action.permit2ApproveUnlimited" : "action.permit2Approve",
                                .address(addr(tokenAddress)), .address(s), .amount(amt), .timestamp(expiration)))

        case .addOwnerWithThreshold(let o, let t):
            let a = addr(o)
            counterparty(a, path: path, chain: chain, into: &findings)
            return safeChange(.addOwner(a, threshold: t), Explanation("action.addOwner", .address(a), .plain(t.description)))
        case .removeOwner(_, let o, let t):
            let a = addr(o)
            return safeChange(.removeOwner(a, threshold: t), Explanation("action.removeOwner", .address(a), .plain(t.description)))
        case .swapOwner(_, let old, let new):
            let o = addr(old), n = addr(new)
            counterparty(n, path: path, chain: chain, into: &findings)
            return safeChange(.swapOwner(old: o, new: n), Explanation("action.swapOwner", .address(o), .address(n)))
        case .changeThreshold(let t):
            return safeChange(.changeThreshold(t), Explanation("action.changeThreshold", .plain(t.description)))
        case .enableModule(let m):
            return safeChange(.enableModule(addr(m)), Explanation("action.enableModule", .address(addr(m))))
        case .disableModule(_, let m):
            return safeChange(.disableModule(addr(m)), Explanation("action.disableModule", .address(addr(m))))
        case .setGuard(let g):
            return safeChange(.setGuard(addr(g)), Explanation(g == .zero ? "action.removeGuard" : "action.setGuard", .address(addr(g))))
        case .setModuleGuard(let g):
            return safeChange(.setModuleGuard(addr(g)), Explanation(g == .zero ? "action.removeModuleGuard" : "action.setModuleGuard", .address(addr(g))))
        case .setFallbackHandler(let h):
            return safeChange(.setFallbackHandler(addr(h)), Explanation("action.setFallbackHandler", .address(addr(h))))
        }
    }

    // MARK: 地址

    private func bookEntry(_ a: Address, chain: UInt64) -> AddressBookEntry? {
        context.addressBook.first { $0.address == a && ($0.chainID == nil || $0.chainID == chain) }
    }

    func info(_ a: Address, chain: UInt64, safe: Address) -> AddressInfo {
        if let s = context.mySafes.first(where: { $0.chainID == chain && $0.address == a }) {
            return AddressInfo(address: a, label: s.name.map { Explanation.sanitize($0) }, source: .mySafe)
        }
        if let b = bookEntry(a, chain: chain) {
            return AddressInfo(address: a, label: Explanation.sanitize(b.label), source: .addressBook)
        }
        if let l = context.labels.lookup(chainID: chain, address: a) {
            return AddressInfo(address: a, label: l.symbol ?? l.name, source: .library(l.kind))
        }
        return AddressInfo(address: a, label: nil, source: .unknown)
    }

    private func tokenInfo(_ a: Address, chain: UInt64) -> TokenInfo {
        guard let l = context.labels.lookup(chainID: chain, address: a), l.isToken else {
            return TokenInfo(address: a, symbol: nil, name: nil, decimals: nil, known: false, kind: nil)
        }
        return TokenInfo(address: a, symbol: l.symbol, name: l.name, decimals: l.decimals, known: true, kind: l.kind)
    }

    /// 收款人 / 授权对象 / 新 owner：R13（代币合约本身）、R05（长得像已知地址）和 R06（首次出现）。
    /// Safe 基础合约在 `visit` 里硬拒，这里不再报。`token` 是正在调用的代币合约（对方就是它自己时也算 R13）。
    private func counterparty(_ a: AddressInfo, path: [Int], chain: UInt64, token: Address? = nil, into findings: inout [Finding]) {
        if isSafeContract(a.address, chain: chain) { return }
        if a.address == token || context.labels.lookup(chainID: chain, address: a.address)?.isToken == true {
            findings.append(Finding(rule: .R13, level: .red, path: path, explanation: Explanation("rule.R13", .address(a)),
                                    subject: .address(a.address)))
            return
        }
        if let similar = lookalike(a.address, chain: chain) {
            let e: Explanation
            switch similar.source {
            case .safeOwner(let safe, let name):
                e = Explanation("rule.R05.safeOwner", .address(a), .address(similar), name.map { .text($0) } ?? .plain(Explanation.shortAddress(safe)))
            case .thisSigner: e = Explanation("rule.R05.thisSigner", .address(a), .address(similar))
            default: e = Explanation("rule.R05", .address(a), .address(similar))
            }
            findings.append(Finding(rule: .R05, level: .red, path: path, explanation: e,
                                    subject: .lookalike(a.address, similarTo: similar.address)))
        } else if !a.isTrustedCounterparty {
            findings.append(Finding(rule: .R06, level: .yellow, path: path,
                                    explanation: Explanation("rule.R06", .address(a)), subject: .address(a.address)))
        }
    }

    /// 比对范围（不按链过滤）：地址簿、我的 Safe、本机签名人地址、已登记 Safe 的签名人（`MySafe.owners`）。
    /// 豁免（`a` 本身算认识的，不报）只认当前链的地址簿条目、当前链的"我的 Safe"和本机签名人地址；
    /// owners 只当比对对象：否则攻击者先诱导用户登记一个 owner 里有仿冒地址的 Safe，就能让这个地址免检。
    /// 按上面的顺序取第一个相似的（当前链的地址簿条目优先），同一个地址只报一次。
    private func lookalike(_ a: Address, chain: UInt64) -> AddressInfo? {
        let me = context.signer?.signerProxy
        guard bookEntry(a, chain: chain) == nil, !context.mySafes.contains(where: { $0.chainID == chain && $0.address == a }),
              a != me else {
            return nil
        }
        // 同一个签名人在几个 Safe 里时，说明里写同一条链上的第一个。
        let safes = context.mySafes.filter { $0.chainID == chain } + context.mySafes.filter { $0.chainID != chain }
        let owners: [(Address, String?, AddressInfo.Source)] = safes.flatMap { s in
            s.owners.filter { $0 != me }.map { ($0, nil, .safeOwner(safe: s.address, name: s.name.map { Explanation.sanitize($0) })) }
        }
        let book = context.addressBook.filter { $0.chainID == nil || $0.chainID == chain }
            + context.addressBook.filter { $0.chainID != nil && $0.chainID != chain }
        let known: [(Address, String?, AddressInfo.Source)] =
            book.map { ($0.address, Explanation.sanitize($0.label), .addressBook) }
            + safes.map { ($0.address, $0.name.map { Explanation.sanitize($0) }, .mySafe) }
            + (me.map { [($0, nil, .thisSigner)] } ?? [])
            + owners
        for (k, label, source) in known where k != a && Self.looksAlike(a, k) {
            return AddressInfo(address: k, label: label, source: source)
        }
        return nil
    }

    /// 开头相同的十六进制位数 + 结尾相同的位数 ≥ `lookalikeMatchChars`。
    static func looksAlike(_ a: Address, _ b: Address) -> Bool {
        let x = Array(a.bytes.hexString.dropFirst(2)), y = Array(b.bytes.hexString.dropFirst(2))
        let prefix = zip(x, y).prefix { $0 == $1 }.count
        let suffix = zip(x.reversed(), y.reversed()).prefix { $0 == $1 }.count
        return prefix + suffix >= lookalikeMatchChars
    }

    // MARK: 拒签说明

    static func explain(_ reason: RejectionReason) -> Explanation {
        switch reason {
        case .malformedRequest: Explanation("reject.malformedRequest")
        case .rawHash: Explanation("reject.rawHash")
        case .unsupportedRequest: Explanation("reject.unsupportedRequest")
        case .unsupportedChain(let c): Explanation("reject.unsupportedChain", .plain(String(c)))
        case .safeNotRegistered(let c, let s):
            Explanation("reject.safeNotRegistered", .plain(Explanation.shortAddress(s)), .plain(String(c)))
        case .decoding(let p, _): Explanation(Self.problemKey(p))
        case .networkOnline: Explanation("reject.networkOnline")
        case .notForThisSigner: Explanation("reject.notForThisSigner")
        case .sendsToSignerAddress: Explanation("reject.sendsToSignerAddress")
        case .counterpartyIsSafeContract(let a): Explanation("reject.counterpartyIsSafeContract", .plain(Explanation.shortAddress(a)))
        case .delegateCallNotAllowed(let a): Explanation("reject.delegateCallNotAllowed", .plain(Explanation.shortAddress(a)))
        case .gasRefundNotSupported(let price, let base, let token, let receiver):
            Explanation("reject.gasRefund", .plain(price.description), .plain(base.description),
                        token == .zero ? .nested(Explanation("gas.nativeToken")) : .plain(Explanation.shortAddress(token)),
                        receiver == .zero ? .nested(Explanation("gas.submitter")) : .plain(Explanation.shortAddress(receiver)))
        }
    }

    static func problemKey(_ p: DecodingProblem) -> String {
        switch p {
        case .malformedArguments: "reject.malformedArguments"
        case .malformedMultiSend: "reject.malformedMultiSend"
        case .multiSendViaCall: "reject.multiSendViaCall"
        case .invalidInnerOperation: "reject.invalidInnerOperation"
        case .delegateCallInCallOnly: "reject.delegateCallInCallOnly"
        case .nestingTooDeep: "reject.nestingTooDeep"
        case .tooManyCalls: "reject.tooManyCalls"
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
