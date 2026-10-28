import Foundation

// 规则层的输入和输出。确认页直接消费 `RiskAssessment`，不再自己解析交易。

// MARK: - 输入

/// "我的 Safe" 里的一项。
public struct MySafe: Hashable, Sendable {
    public var chainID: UInt64
    public var address: Address
    public var name: String?
    /// 登记时（或 Signer 最后一次确认时）的 owner 和门限，用于改 owner 时显示前后对比（F4）。
    /// 链上状态可能已经变了，界面要注明"以登记时为准"。
    public var owners: [Address]
    public var threshold: UInt64?

    public init(chainID: UInt64, address: Address, name: String? = nil, owners: [Address] = [], threshold: UInt64? = nil) {
        self.chainID = chainID
        self.address = address
        self.name = name
        self.owners = owners
        self.threshold = threshold
    }

    /// 从核对过的登记生成。
    public init(registration r: SafeRegistration) {
        self.init(chainID: r.chainID, address: r.safe, name: r.name, owners: r.owners, threshold: r.threshold)
    }
}

/// 这台 Signer 的身份：发给它的 `eth-sign-request` 必须指向它（docs/ur-types.md「发给我们自己 Signer 的请求」）。
public struct SignerIdentity: Hashable, Sendable {
    /// `SignerPairing.keyFingerprint(x:y:)`。
    public var keyFingerprint: UInt32
    /// 这台 Signer 的 WebAuthn signer proxy 地址（Safe 里的 owner）。
    public var signerProxy: Address

    public init(keyFingerprint: UInt32, signerProxy: Address) {
        self.keyFingerprint = keyFingerprint
        self.signerProxy = signerProxy
    }
}

/// Signer 上的地址簿条目（新地址首次出现要在 Signer 上确认才入库）。
public struct AddressBookEntry: Hashable, Sendable {
    public var address: Address
    /// 用户起的名字。外部字符串，只当数据显示。
    public var label: String
    /// nil 表示所有链。
    public var chainID: UInt64?

    public init(address: Address, label: String, chainID: UInt64? = nil) {
        self.address = address
        self.label = label
        self.chainID = chainID
    }
}

public struct RiskContext: Sendable {
    public var mySafes: [MySafe]
    public var addressBook: [AddressBookEntry]
    public var labels: LabelLibrary
    /// R11：签名时 Wi-Fi / 蜂窝接口有可路由地址。由调用方（Signer 的 getifaddrs 检查）传入。
    public var networkOnline: Bool
    /// 给定时，`assess(signRequest:)` 要求请求的 derivation-path / address 指向这台 Signer。
    public var signer: SignerIdentity?

    public init(mySafes: [MySafe], addressBook: [AddressBookEntry] = [], labels: LabelLibrary = .builtIn,
                networkOnline: Bool = false, signer: SignerIdentity? = nil) {
        self.mySafes = mySafes
        self.addressBook = addressBook
        self.labels = labels
        self.networkOnline = networkOnline
        self.signer = signer
    }
}

// MARK: - 地址、代币、金额

public struct AddressInfo: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case mySafe
        case addressBook
        /// 已登记的某个 Safe 的签名人（登记时记下的 owner）。`name` 是那个 Safe 的名字（外部字符串，已清理）。
        /// 只出现在 R05 的"相似的已知地址"里。
        case safeOwner(safe: Address, name: String?)
        /// 这台签名器自己的签名人地址。只出现在 R05 的"相似的已知地址"里。
        case thisSigner
        case library(LabelLibrary.Kind)
        case unknown
    }

    public var address: Address
    /// 标签（我的 Safe 名 / 地址簿名 / 标签库名）。外部字符串，已清理控制字符和方向控制符。
    public var label: String?
    public var source: Source

    public var isKnown: Bool { source != .unknown }
    /// 作为收款人 / 授权对象 / operator / 新 owner 时算"认识的对方"：只有地址簿和"我的 Safe"。
    /// 标签库里的地址只说明它是什么合约，不说明可以把资产交给它。
    public var isTrustedCounterparty: Bool { source == .addressBook || source == .mySafe }

    public init(address: Address, label: String?, source: Source) {
        self.address = address
        self.label = label
        self.source = source
    }
}

public struct TokenInfo: Hashable, Sendable {
    public var address: Address
    public var symbol: String?
    public var name: String?
    public var decimals: Int?
    /// 标签库里认识这个合约。
    public var known: Bool
    public var kind: LabelLibrary.Kind?
}

public struct TokenAmount: Hashable, Sendable {
    public var raw: UInt256
    public var decimals: Int?
    public var symbol: String?

    public init(raw: UInt256, decimals: Int?, symbol: String?) {
        self.raw = raw
        self.decimals = decimals
        self.symbol = symbol
    }

    /// 有 decimals 时按小数显示（千分位逗号，去掉末尾的 0）；没有时显示原始整数和"最小单位"。
    public var formatted: String {
        guard let decimals else { return Self.group(raw.description) }
        let digits = raw.description
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let intPart = String(padded.dropLast(decimals))
        let frac = String(padded.suffix(decimals)).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return Self.group(intPart) + (frac.isEmpty ? "" : "." + frac)
    }

    static func group(_ s: String) -> String {
        var out = ""
        for (i, c) in s.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return String(out.reversed())
    }
}

// MARK: - 动作

/// Safe 自身配置的变更（R02）。
public enum SafeConfigChange: Hashable, Sendable {
    case addOwner(AddressInfo, threshold: UInt256)
    case removeOwner(AddressInfo, threshold: UInt256)
    case swapOwner(old: AddressInfo, new: AddressInfo)
    case changeThreshold(UInt256)
    case enableModule(AddressInfo)
    case disableModule(AddressInfo)
    case setGuard(AddressInfo)
    case setModuleGuard(AddressInfo)
    case setFallbackHandler(AddressInfo)
    /// 对 Safe 自己的其它调用（不认识的选择器）。
    case otherSelfCall(selector: Data?)
}

public enum ActionKind: Hashable, Sendable {
    /// 只转原生币（没有调用数据）。
    case nativeTransfer(to: AddressInfo, amount: TokenAmount)
    /// 没有调用数据也不带币的空调用。
    case emptyCall(AddressInfo)
    case tokenTransfer(token: TokenInfo, from: AddressInfo?, to: AddressInfo, amount: TokenAmount)
    case nftTransfer(collection: TokenInfo, from: AddressInfo, to: AddressInfo, tokenID: UInt256, amount: UInt256?)
    /// ERC-1155 `safeBatchTransferFrom`：`ids` 和 `amounts` 一一对应。
    case nftBatchTransfer(collection: TokenInfo, from: AddressInfo, to: AddressInfo, ids: [UInt256], amounts: [UInt256])
    /// 不认识的合约上的 `transferFrom(a, b, x)`：x 可能是数量也可能是 tokenId，不做解释。
    case unknownTransferFrom(contract: TokenInfo, from: AddressInfo, to: AddressInfo, value: UInt256)
    case approval(token: TokenInfo, spender: AddressInfo, amount: TokenAmount, unlimited: Bool)
    case allowanceChange(token: TokenInfo, spender: AddressInfo, delta: TokenAmount, increase: Bool, unlimited: Bool)
    case approvalForAll(collection: TokenInfo, operator: AddressInfo, approved: Bool)
    case permit2Approval(token: TokenInfo, spender: AddressInfo, amount: TokenAmount, expiration: UInt64, unlimited: Bool)
    case safeConfig(SafeConfigChange)
    case multiSend(MultiSendContract, count: Int)
    /// 认识目标但不认识函数（或调用数据不足 4 字节）。
    case contractCall(target: AddressInfo, selector: Data?)
    /// 解码有问题的调用（对应的拒签原因在 `RiskAssessment.rejections`）。
    case invalid(DecodingProblem)
}

/// 展开后的一条调用，确认页按顺序显示。
public struct ActionSummary: Hashable, Sendable {
    /// 在 MultiSend 树里的位置：顶层是 []，第一条子调用是 [0]，嵌套的是 [0, 2]。
    public var path: [Int]
    public var operation: SafeTx.Operation
    /// 实际被调用的地址。
    public var target: AddressInfo
    /// 随调用一起转出的原生币（0 时为 nil）。
    public var nativeValue: TokenAmount?
    public var kind: ActionKind
    public var explanation: Explanation
    /// 命中的规则（包括拒签原因对应的条目）。
    public var level: RiskLevel
}

// MARK: - 规则结果

public enum RuleID: String, Hashable, Sendable, CaseIterable {
    case R01, R02, R03, R05, R06, R07, R08, R09, R12, R13
}

public enum RiskLevel: Int, Comparable, Hashable, Sendable {
    case green = 0, yellow, red

    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
}

/// 可越过的发现项（黄 / 红）。红的需要用户输入确认短语才能继续。
public struct Finding: Hashable, Sendable {
    public var rule: RuleID
    public var level: RiskLevel
    public var path: [Int]
    public var explanation: Explanation
    /// 这条发现项"关于"什么：越过红色时，确认短语要求输入它的后 4 位（见 `ConfirmationPhrase`）。
    public var subject: Subject?

    public enum Subject: Hashable, Sendable {
        case address(Address)
        /// 例如 changeThreshold 的新门限。
        case number(String)
        /// 不认识的函数选择器（十六进制，不带 0x）。
        case selector(String)
        /// R05：这个地址和地址簿 / 我的 Safe 里的 `similarTo` 首尾相同、中间不同。
        case lookalike(Address, similarTo: Address)
    }

    public init(rule: RuleID, level: RiskLevel, path: [Int], explanation: Explanation, subject: Subject? = nil) {
        self.rule = rule
        self.level = level
        self.path = path
        self.explanation = explanation
        self.subject = subject
    }
}

/// 硬拒的原因。和 `Finding` 是不同的类型：硬拒没有越过的入口。
public enum RejectionReason: Hashable, Sendable {
    /// 请求本身解析失败（UR、EIP-712 JSON、字段）。
    case malformedRequest(String)
    /// 裸哈希签名请求（personal_sign 32 字节）。
    case rawHash
    /// 不是 EIP-712 SafeTx 的请求（v1 只签 SafeTx）。
    case unsupportedRequest(EthSignRequest.DataType)
    /// 不在首发链上。
    case unsupportedChain(UInt64)
    /// Safe 不在"我的 Safe"里。
    case safeNotRegistered(chainID: UInt64, safe: Address)
    /// 解码出的问题（不能执行或编码不规范）。
    case decoding(DecodingProblem, path: [Int])
    /// R11：联网时拒签。
    case networkOnline
    /// 请求的 derivation-path 指纹或 address 不是这台 Signer。
    case notForThisSigner
    /// 用了 Safe 的 gas 退款：gasPrice / baseGas 不为 0，或 gasToken / refundReceiver 不是零地址。
    /// 执行时 Safe 会在交易本身之外，再从自己的余额付一笔"退款"。v1 不用退款机制，一律硬拒。
    case gasRefundNotSupported(gasPrice: UInt256, baseGas: UInt256, gasToken: Address, refundReceiver: Address)
    /// 把资产（ETH、代币、NFT）转给这台 Signer 自己的 signer proxy。proxy 只是 Safe 的签名人合约，
    /// 没有提款功能：已部署时 ETH 会回滚，但代币能转进去；在还没部署的链上 ETH 也能转进去。转进去就永久取不回。
    case sendsToSignerAddress
    /// 收款人 / 授权对象 / operator / 新 owner 是 Safe 的基础合约（singleton、proxy factory、fallback handler、
    /// MultiSend 等库合约、WebAuthn signer factory）或 Permit2（ERC-20 approve 给 Permit2 除外）。
    /// 这些合约谁都能调用（例如 MultiSendCallOnly 没有"只能被 DELEGATECALL"的限制），授权或转给它们的资产任何人都能取走。
    case counterpartyIsSafeContract(Address)
    /// DELEGATECALL 到官方 MultiSend 和少数官方升级 / 部署库（`SafeDeployments.delegateCallLibraries`）以外的合约。
    /// 被调用的代码以这个 Safe 的身份运行，能改它的存储（Bybit 就是这样被换掉实现合约的）；正常使用完全不会出现。
    case delegateCallNotAllowed(Address)
}

public struct Rejection: Hashable, Sendable {
    public var reason: RejectionReason
    public var explanation: Explanation
}

public enum Verdict: Hashable, Sendable {
    case green
    case yellow
    /// 有红色发现项：可以越过，但要输入确认短语。
    case red
    /// 硬拒，不能越过。
    case rejected
}

public struct RiskAssessment: Hashable, Sendable {
    /// 解析成功时才有。注意：被拒时也可能有，签名入口必须看 `verdict`（`SignableTransaction`）。
    public var request: SafeTxRequest?
    /// 来自 `eth-sign-request`，签名回传时原样带回。直接评估 `SafeTxRequest` 时为 nil。
    public var requestID: Data?
    public var actions: [ActionSummary]
    public var findings: [Finding]
    public var rejections: [Rejection]

    public init(request: SafeTxRequest?, requestID: Data? = nil, actions: [ActionSummary], findings: [Finding], rejections: [Rejection]) {
        self.request = request
        self.requestID = requestID
        self.actions = actions
        self.findings = findings
        self.rejections = rejections
    }

    public var verdict: Verdict {
        if !rejections.isEmpty { return .rejected }
        switch findings.map(\.level).max() ?? .green {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        }
    }

    /// 命中的规则 id（去重，按出现顺序）。
    public var ruleIDs: [RuleID] {
        var seen: [RuleID] = []
        for f in findings where !seen.contains(f.rule) { seen.append(f.rule) }
        return seen
    }

    /// 命中 R05 的地址（长得像已知地址的仿冒地址），包括 MultiSend 内层调用里的。
    public var lookalikeAddresses: Set<Address> {
        Set(findings.compactMap { f in
            if case .lookalike(let a, _)? = f.subject { a } else { nil }
        })
    }

    /// 对方地址（收款人、授权对象等）要不要标"首次出现"并提供"加入地址簿"：只在它命中 R06 时，且不是本机签名人地址。
    /// 命中 R05 的只显示和已知地址的并排对比：把仿冒地址存进地址簿，正是地址投毒想要的结果；
    /// Safe 基础合约、代币合约本身（拒签 / R13）也不提供。
    public func isFirstSeen(_ info: AddressInfo, thisSigner: Address? = nil) -> Bool {
        info.address != thisSigner && !lookalikeAddresses.contains(info.address)
            && findings.contains { $0.rule == .R06 && $0.subject == .address(info.address) }
    }
}
