import Foundation

/// 越过红色时要输入的确认短语：每条红色发现项"关于"的那个东西的 4 位，空格分隔，顺序和大小写不限。
/// 目的是让用户真的去看那个有风险的地方，而不是输入一句固定的"我确认"。
///
/// - 地址：十六进制后 4 位；门限：整个数字；选择器：后 4 位。
/// - **R05（地址投毒）例外**：后 4 位恰恰是投毒地址照着真地址伪造的部分，看了也分不出来。所以取两个地址
///   **第一处不同的位置**开始的 4 个字符（不够 4 位时往前挪，窗口始终包含那个不同的字符）。用户要输对，
///   就必须看到两个地址不一样的地方。
public struct ConfirmationPhrase: Hashable, Sendable {
    public struct Token: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case lastFour(Address)
            case number(String)
            case selector(String)
            /// 从第一处不同的位置（十六进制下标，不含 0x）开始的 4 位。
            case firstDifference(Address, similarTo: Address, start: Int)
            /// 地址从 `start`（十六进制下标，不含 0x）开始的 4 位：默认取法的字符和别的条目撞了时换用。
            case addressWindow(Address, start: Int)
            /// 最后的兜底：门限或选择器的字符和别的条目撞了时，输入"规则号-序号"（例如 R02-2）。
            case ruleNumber(Int)
            /// 兜底：没有可引用的对象时输入规则号。
            case ruleID
        }

        public var rule: RuleID
        public var path: [Int]
        public var kind: Kind
        /// 期望输入（大写）。
        public var expected: String
    }

    public let tokens: [Token]

    /// 两个不同地址第一处不同的十六进制位置，以及从那里开始（必要时往前挪）的 4 位窗口的起点。
    public static func differenceWindow(_ a: Address, _ b: Address) -> (firstDifference: Int, start: Int) {
        let ha = Array(a.bytes.hexString.dropFirst(2)), hb = Array(b.bytes.hexString.dropFirst(2))
        let i = ha.indices.first { ha[$0] != hb[$0] } ?? 0
        return (i, min(i, ha.count - 4))
    }

    /// R08 只是汇总，不单独要求输入（它的子调用已经各自在列）。
    ///
    /// 按（规则、位置、对象）去重，不按字符串值去重（安全核查 P2-4）：两条红色发现项默认要求的 4 位撞了，
    /// 后来的一条换一个窗口（同一地址的别的 4 位），保证每条红色都要单独输入、输一次不能同时放过两条。
    public init(_ a: RiskAssessment) {
        struct Key: Hashable { let rule: RuleID; let path: [Int]; let subject: Finding.Subject }
        var seen = Set<Key>()
        var used = Set<String>()
        var tokens: [Token] = []
        for f in a.findings where f.level == .red && f.rule != .R08 {
            guard let s = f.subject, seen.insert(Key(rule: f.rule, path: f.path, subject: s)).inserted else { continue }
            var pick = Self.candidates(s).first { !$0.value.isEmpty && !used.contains($0.value) }
            if pick == nil {
                var n = tokens.count + 1
                while used.contains("\(f.rule.rawValue)-\(n)") { n += 1 }
                pick = (.ruleNumber(n), "\(f.rule.rawValue)-\(n)")
            }
            used.insert(pick!.value)
            tokens.append(Token(rule: f.rule, path: f.path, kind: pick!.kind, expected: pick!.value))
        }
        // 兜底：红色但没有可引用的对象时，至少要求输入规则号，不能空输入通过。
        if tokens.isEmpty, let f = a.findings.first(where: { $0.level == .red }) {
            tokens = [Token(rule: f.rule, path: f.path, kind: .ruleID, expected: f.rule.rawValue)]
        }
        self.tokens = tokens
    }

    /// 一个对象可以要求输入的字符，按优先顺序。地址：后 4 位，然后往前每 4 位一个窗口；
    /// R05：第一处不同的位置开始的 4 位，然后同一地址的其它窗口。
    static func candidates(_ s: Finding.Subject) -> [(kind: Token.Kind, value: String)] {
        func window(_ x: Address, _ start: Int) -> String {
            String(Array(x.bytes.hexString.dropFirst(2))[start..<start + 4]).uppercased()
        }
        switch s {
        case .address(let x):
            return [(.lastFour(x), window(x, 36))] + stride(from: 32, through: 0, by: -4).map { (.addressWindow(x, start: $0), window(x, $0)) }
        case .number(let n):
            return [(.number(n), n)]
        case .selector(let h):
            return [(.selector(h), String(h.suffix(4)).uppercased())]
        case .lookalike(let x, let similar):
            let w = Self.differenceWindow(x, similar).start
            let others = (stride(from: w - 4, through: 0, by: -4).map { $0 } + stride(from: w + 4, through: 36, by: 4).map { $0 })
            return [(.firstDifference(x, similarTo: similar, start: w), window(x, w))] + others.map { (.addressWindow(x, start: $0), window(x, $0)) }
        }
    }

    /// 输入里的词（不分大小写、去掉 0x）必须正好覆盖全部期望值，不多不少。
    public func matches(_ input: String) -> Bool {
        let words = input.uppercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "，" || $0 == "、" })
            .map { $0.hasPrefix("0X") ? String($0.dropFirst(2)) : String($0) }
        return Set(words) == Set(tokens.map(\.expected)) && words.count == tokens.count
    }
}

/// 能签的交易。只能从**没被拒**的 `RiskAssessment` 构造；红色还要求确认短语。
/// 签名函数只接受这个类型，所以"界面没显示按钮"不是唯一的防线。
public struct SignableTransaction: Hashable, Sendable {
    public enum Refusal: Error, Hashable, Sendable {
        /// verdict 是 `.rejected`（即使 assessment 里带着 request）。
        case rejected([RejectionReason])
        case noRequest
        case missingRequestID
        /// 红色，没给确认短语。
        case confirmationRequired
        case confirmationMismatch
    }

    public let assessment: RiskAssessment
    /// 签名的 challenge：评估时重算出的 safeTxHash，不取请求里的任何其它字段。
    public let challenge: Data
    public let requestID: Data
    public let request: SafeTxRequest

    public init(_ a: RiskAssessment, confirmation: String? = nil) throws {
        guard a.verdict != .rejected, a.rejections.isEmpty else { throw Refusal.rejected(a.rejections.map(\.reason)) }
        guard let request = a.request else { throw Refusal.noRequest }
        guard let requestID = a.requestID, requestID.count == 16 else { throw Refusal.missingRequestID }
        if a.verdict == .red {
            guard let confirmation else { throw Refusal.confirmationRequired }
            guard ConfirmationPhrase(a).matches(confirmation) else { throw Refusal.confirmationMismatch }
        }
        self.assessment = a
        self.request = request
        self.requestID = requestID
        self.challenge = request.safeTxHash
    }
}
