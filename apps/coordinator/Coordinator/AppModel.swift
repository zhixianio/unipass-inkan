import CoordinatorFlow
import Foundation
import SafeTransactionService
import SubmitterAccount
import UniPassCore

/// 全 App 共享的状态：配对的签名器（可以有几台）的公钥和 proxy 地址、地址簿（都是公开数据）。桌面端不持有 Safe owner 的密钥；
/// 只保管一个付网络费的提交账户（私钥在钥匙串）。
@Observable
final class AppModel {
    private static let pairedSignersKey = SavedState.pairedSignersKey
    private static let addressBookKey = SavedState.addressBookKey
    private static let safesKey = SavedState.safesKey

    /// 配对过的签名器。签名请求发给其中在这个 Safe 里、还没签的那一台。
    private(set) var signers: PairedSigners {
        didSet { saveSigners() }
    }

    var addressBook: AddressBook {
        didSet { save(addressBook, Self.addressBookKey) }
    }

    /// 这台 Mac 上的 Safe（创建或添加时写入，存完整的创建参数）。
    private(set) var store: SafeStore {
        didSet { safesChanged(from: oldValue) }
    }

    /// 当前选中的 Safe 的链上状态。一个 Safe 都没有时为 nil（主窗口显示"创建或添加"）。
    private(set) var safe: SafeState?

    /// 提交账户：替用户把签齐的交易发上链的普通 EOA，不是 owner。
    let submitter = SubmitterModel()

    /// 主窗口当前的页面和弹窗（菜单命令也能切换）。
    var page: Page = .home
    var sending = false
    var receiving = false
    var creatingSafe = false
    var addingSafe = false

    /// 欢迎引导走完了没有。
    var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: SavedState.onboardedKey) }
    }

    #if DEBUG
    let attackDemo = AttackDemoState()
    /// 启动参数 `-InkanDemo YES`：打开攻击演示（docs/demo.md）。不带时界面上没有任何演示的痕迹。
    let demoEnabled = UserDefaults.standard.bool(forKey: "InkanDemo")
    /// 启动参数 `-InkanDeveloper YES`：开发者菜单、模拟配对、技术细节里的调试字段。
    let developerMode = UserDefaults.standard.bool(forKey: "InkanDeveloper")
    let developer = DeveloperState()
    #endif

    /// 开发者模式（只在 DEBUG 构建里可能为 true）。
    var isDeveloper: Bool {
        #if DEBUG
        developerMode
        #else
        false
        #endif
    }

    init() {
        let saved = SavedState.load(.standard)
        signers = saved.signers
        addressBook = Self.load(AddressBook.self, Self.addressBookKey) ?? AddressBook()
        onboarded = saved.onboarded
        store = saved.store
        safe = store.current.map { SafeState(registration: $0) }
        submitter.safes = Set(store.safes.map { SigningPolicy.RegisteredSafe(chainID: $0.chainID, address: $0.safe) })
    }

    private func saveSigners() {
        guard let data = try? signers.encoded() else { return }
        UserDefaults.standard.set(data, forKey: Self.pairedSignersKey)
    }

    /// 配对一台签名器（同一台再配对时更新它；同一个 proxy 换了公钥的不收）。返回存下来的那条（名字可能加了编号）。
    /// 调用前先过 `PairingCheck`。
    @discardableResult
    func pair(_ s: PairedSigner) throws(PairedSigners.KeyChanged) -> PairedSigner {
        try signers.add(s)
    }

    func unpair(_ proxy: Address) {
        signers.remove(proxy)
    }

    func renameSigner(_ proxy: Address, to name: String) -> PairedSigners.RenameProblem? {
        signers.rename(proxy, to: name)
    }

    /// 这个 Safe 里已配对的签名器，按 owner 的顺序。签名请求只能发给它们。
    func signers(for safe: SafeState) -> [PairedSigner] {
        signers.inSafe(safe.ownerList)
    }

    /// 当前 Safe 里至少有一台已配对的签名器，才能从这台 Mac 发起交易。
    var canSend: Bool {
        safe.map { !signers(for: $0).isEmpty } ?? false
    }

    private func safesChanged(from old: SafeStore) {
        if let data = try? store.encoded() { UserDefaults.standard.set(data, forKey: Self.safesKey) }
        submitter.safes = Set(store.safes.map { SigningPolicy.RegisteredSafe(chainID: $0.chainID, address: $0.safe) })
        if store.current != old.current || safe?.registration != store.current {
            safe = store.current.map { SafeState(registration: $0) }
        }
    }

    /// 创建或添加的 Safe 存进列表并切换过去。
    func addSafe(_ r: SafeRegistration) {
        store.add(r)
    }

    func removeSafe(_ id: SafeStore.SafeID) {
        store.remove(id)
    }

    func selectSafe(_ id: SafeStore.SafeID) {
        store.select(id)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save(_ value: (some Encodable)?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 每条链用哪个 RPC 节点：设置 › 高级里自己填的（存钥匙串），没填用默认的公共节点。App 里所有链上读写都走这里。
    var rpcEndpoints = RPCEndpoints.load()

    func rpc(chainID: UInt64) -> EthRPC? {
        rpcEndpoints.url(chainID: chainID).map { EthRPC(url: $0) }
    }

    /// 改了某条链的节点：存钥匙串，再按新节点刷新。
    func setRPCEndpoint(_ url: URL?, chainID: UInt64) throws {
        var e = rpcEndpoints
        e.set(url, chainID: chainID)
        try e.save()
        rpcEndpoints = e
        Task { await refresh() }
    }

    func sts(chainID: UInt64) -> STSClient? {
        SafeChain.known.first { $0.chainId == chainID }.map { STSClient(chain: $0, apiKey: SafeAPIKey.resolve()) }
    }

    /// 地址在界面上的名字：配对的签名器用这台 Mac 上给它起的名字，其他看地址簿。
    func name(for a: Address) -> String? {
        if let s = signers.signer(a) { return s.name }
        if let r = store.safes.first(where: { $0.safe == a }) { return r.name ?? AddressDisplay.short(r.safe) }
        return addressBook.name(for: a)
    }

    /// 签名合约地址（不能收款）：已配对签名器的地址，或者当前 Safe 里链上有代码的签名人。界面上用来加提醒、去掉复制按钮。
    func isSignerContract(_ a: Address) -> Bool {
        SignerAddresses.isSignerContract(a, pairedSigners: signers.proxies,
                                         safeOwners: Set(safe?.ownerList ?? []), hasCode: safe?.contractOwners.contains(a) == true)
            || knownSignerContracts.contains(a)
    }

    /// 发送和存地址簿之前的检查：除了上面那些，还看这台 Mac 上所有 Safe 的签名人在 `chainID` 上有没有代码。
    func checkSignerContract(_ a: Address, chainID: UInt64) async -> Bool {
        if isSignerContract(a) { return true }
        let owners = Set(store.safes.flatMap(\.owners))
        guard owners.contains(a), let rpc = rpc(chainID: chainID), let code = try? await rpc.code(at: a) else { return false }
        let isContract = SignerAddresses.isSignerContract(a, pairedSigners: signers.proxies, safeOwners: owners, hasCode: !code.isEmpty)
        if isContract { knownSignerContracts.insert(a) }
        return isContract
    }

    @ObservationIgnored private var knownSignerContracts: Set<Address> = []

    /// 地址簿加上配对的签名器（给交易摘要找名字）。
    var namingBook: AddressBook {
        var book = addressBook
        for s in signers.all { book.save(name: s.name, address: s.signerProxy) }
        return book
    }

    func summary(_ request: SafeTxRequest) -> TransactionSummary {
        TransactionSummary.describe(request, addressBook: namingBook)
    }

    func refresh() async {
        guard let safe else { return }
        await safe.refresh(rpc: rpc(chainID: safe.chainID), sts: sts(chainID: safe.chainID))
    }

    /// 提交账户余额等显示用的网络：当前 Safe 的网络；还没有 Safe 时用 Sepolia。
    var chainID: UInt64 { safe?.chainID ?? 11_155_111 }
}

/// 一个 Safe 的链上状态和交易记录。都是公开数据，打开页面时刷新。
@Observable
final class SafeState {
    let registration: SafeRegistration
    var assets: [Asset]
    var nonce: UInt256?
    var threshold: Int?
    var owners: [Address]?
    /// 链上有代码的签名人（签名合约、合约账户）：不能当收款人，界面上不给复制。
    var contractOwners: Set<Address> = []
    /// 交易服务里的记录，按编号倒序（同一个编号可能有被替换掉的）。
    var transactions: [MultisigTransaction] = []
    var baseFee: UInt256?
    var tip: UInt256?
    var loading = false
    /// 最近一轮刷新（含重试）之后还是读不到的部分；nil = 都读到了。
    var loadFailure: LoadFailure?
    var loadFailed: Bool { loadFailure != nil }

    enum LoadFailure {
        /// 区块链节点（余额、签名人、门限）。
        case node
        /// Safe 交易服务（交易记录）。
        case service
        case both
    }
    var lastRefresh: Date?
    /// 加进来以后 module、guard、fallback handler、singleton 变了的项：区块链节点或交易服务任一方报的都算。空 = 没变。
    var configurationChanges: Set<ExistingSafe.Field> { nodeChanges.union(serviceChanges) }
    private var nodeChanges: Set<ExistingSafe.Field> = []
    private var serviceChanges: Set<ExistingSafe.Field> = []

    init(registration: SafeRegistration) {
        self.registration = registration
        assets = Asset.known(chainID: registration.chainID)
    }

    var chainID: UInt64 { registration.chainID }
    var address: Address { registration.safe }
    var name: String { registration.name ?? AddressDisplay.short(registration.safe) }
    var ownerList: [Address] { owners ?? registration.owners }
    var thresholdValue: Int { threshold ?? Int(clamping: registration.threshold) }

    /// 刷新：同一时刻只跑一轮（正在刷新时再调用就等这一轮结束）。读不到的部分按 2s、5s、10s 退避重试，
    /// 三次都失败才记下失败（界面上才出横幅），并分清是区块链节点还是 Safe 交易服务。
    func refresh(rpc: EthRPC?, sts: STSClient?) async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { await refreshWithRetries(rpc: rpc, sts: sts) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    static let retryDelays: [Double] = [2, 5, 10]

    private func refreshWithRetries(rpc: EthRPC?, sts: STSClient?) async {
        loading = true
        defer { loading = false }
        var nodeOK = rpc == nil
        var serviceOK = sts == nil
        for delay in [0] + Self.retryDelays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if !nodeOK, let rpc { nodeOK = await loadChain(rpc) }
            if !serviceOK, let sts { serviceOK = await loadService(sts) }
            if nodeOK && serviceOK { break }
        }
        loadFailure = switch (nodeOK, serviceOK) {
        case (true, true): nil
        case (false, true): .node
        case (true, false): .service
        case (false, false): .both
        }
        lastRefresh = .now
        trackConfirming()
    }

    /// 链上的 nonce、门限、签名人、module / guard / fallback handler / singleton、余额、网络费。全部读到才算成功。
    private func loadChain(_ rpc: EthRPC) async -> Bool {
        var ok = true
        do {
            async let n = rpc.safeNonce(address)
            async let s = rpc.existingSafeState(address)
            let state = try await s
            (nonce, threshold, owners) = (try await n, Int(clamping: state.threshold), state.owners)
            nodeChanges = ExistingSafe.configurationChanges(registration, now: state)
            var contracts: Set<Address> = []
            for owner in ownerList {
                if let code = try? await rpc.code(at: owner), !code.isEmpty { contracts.insert(owner) }
            }
            contractOwners = contracts
        } catch {
            ok = false
        }
        var failedBalance = false
        assets = await withTaskGroup(of: (Int, UInt256?).self) { group in
            for (i, asset) in assets.enumerated() {
                group.addTask { [address] in
                    switch asset.kind {
                    case .native: (i, try? await rpc.balance(of: address))
                    case .erc20(let token): (i, try? await rpc.tokenBalance(token: token, owner: address))
                    }
                }
            }
            var out = assets
            for await (i, balance) in group {
                if let balance { out[i].balance = balance } else { failedBalance = true }
            }
            return out
        }
        baseFee = try? await rpc.baseFee()
        tip = try? await rpc.maxPriorityFeePerGas()
        return ok && !failedBalance
    }

    /// 交易服务里最近 30 笔记录，和它报的 module / guard / fallback handler / singleton（复查用）。
    private func loadService(_ sts: STSClient) async -> Bool {
        do {
            transactions = MultisigTransaction.merge(fetched: try await sts.multisigTransactions(address, limit: 30).results, known: transactions)
            // 刚创建的 Safe 交易服务可能还没收录：读不到时只是这一项不复查（节点那边照样查），不算刷新失败。
            if let state = try? await sts.safeInfo(address).state {
                serviceChanges = ExistingSafe.configurationChanges(registration, now: state)
            }
            return true
        } catch {
            return false
        }
    }

    /// 等签名或等执行的笔数（侧边栏"活动"的角标）。
    var pendingCount: Int { transactions.filter { status(of: $0).isPending }.count }

    /// 测试网（界面上要明显标出来）。
    var isTestnet: Bool { Display.isTestnet(chainID) }

    /// 列表里的这一笔的最新记录（详情页显示它，不显示打开时的那份）。
    func transaction(_ safeTxHash: String) -> MultisigTransaction? {
        transactions.first { $0.safeTxHash == safeTxHash }
    }

    /// 单笔查询到的新状态（刚保存的签名、刚上链）写回列表，不用等下一次刷新。
    func update(_ tx: MultisigTransaction) {
        transactions = MultisigTransaction.merge(fetched: [tx], known: transactions.filter { $0.safeTxHash == tx.safeTxHash })
            + transactions.filter { $0.safeTxHash != tx.safeTxHash }
        transactions.sort { $0.nonce.value > $1.nonce.value }
        trackConfirming()
    }

    /// 新交易用的编号：链上当前的 nonce（排队中同编号的交易会被这一笔替换）。
    var nextNonce: UInt256? { nonce }

    /// 交易服务记录里的这一笔，前提是本地重算的哈希和服务给的一致（不信任服务返回的哈希）。
    func request(for tx: MultisigTransaction) -> SafeTxRequest? {
        guard let safeTx = try? tx.safeTx() else { return nil }
        let r = SafeTxRequest(chainID: chainID, safe: address, tx: safeTx)
        return r.safeTxHash.hexString == tx.safeTxHash.lowercased() ? r : nil
    }

    func status(of tx: MultisigTransaction) -> QueueStatus {
        _ = clock // 到了超时的时间点重新计算
        return tx.status(safeNonce: nonce, siblings: transactions)
            .timingOut(since: confirmingSince[tx.safeTxHash], now: .now, timeout: Self.confirmingTimeout)
    }

    /// 每笔交易第一次显示"正在确认"的时间；超过 `confirmingTimeout` 还没同步过来就改成"状态还没确认"。
    @ObservationIgnored private var confirmingSince: [String: Date] = [:]
    /// 到了某笔交易的超时时间点时更新，让界面重新算状态。
    private var clock = Date()
    static let confirmingTimeout: TimeInterval = 120

    /// 交易记录或链上 nonce 变了之后调用：记下新出现的"正在确认"，排好超时的那一刻。
    private func trackConfirming() {
        let now = Date()
        var since: [String: Date] = [:]
        for tx in transactions where tx.status(safeNonce: nonce, siblings: transactions) == .confirming {
            since[tx.safeTxHash] = confirmingSince[tx.safeTxHash] ?? now
        }
        confirmingSince = since
        guard let earliest = since.values.min() else { return }
        let wait = earliest.addingTimeInterval(Self.confirmingTimeout).timeIntervalSince(now)
        Task {
            try? await Task.sleep(for: .seconds(max(wait, 0) + 0.5))
            clock = .now
        }
    }

    /// 估算执行这笔交易的网络费。
    func estimatedFee(_ tx: SafeTx) -> UInt256? {
        guard let baseFee, let tip else { return nil }
        return FeeEstimate.fee(gas: FeeEstimate.executionGas(tx), baseFee: baseFee, tip: tip)
    }

    var nativeAsset: Asset { assets.first { $0.kind == .native } ?? .native(chainID: chainID) }
}

extension EthRPC {
    /// 节点读的 Safe 当前状态：owners、门限、module、guard 槽、fallback handler 槽、singleton 槽。
    func existingSafeState(_ safe: Address) async throws -> ExistingSafe.OnChain {
        async let owners = safeOwners(safe)
        async let threshold = safeThreshold(safe)
        async let modules = safeModules(safe)
        async let guardWord = storage(at: safe, slot: ExistingSafe.guardSlot)
        async let fallbackWord = storage(at: safe, slot: ExistingSafe.fallbackHandlerSlot)
        async let singletonWord = storage(at: safe, slot: ExistingSafe.singletonSlot)
        return ExistingSafe.OnChain(
            owners: try await owners, threshold: (try await threshold).words[0], modules: try await modules,
            guardAddress: Address(bytes: (try await guardWord).suffix(20))!,
            fallbackHandler: Address(bytes: (try await fallbackWord).suffix(20))!,
            singleton: Address(bytes: (try await singletonWord).suffix(20))!)
    }
}

extension SafeInfo {
    /// 交易服务 `/safes/{address}/` 报的当前状态；有地址读不出来时为 nil。
    var state: ExistingSafe.OnChain? {
        let owners = owners.compactMap(Address.init(hex:))
        let modules = modules.compactMap(Address.init(hex:))
        guard owners.count == self.owners.count, modules.count == self.modules.count, threshold >= 0,
              let g = Address(hex: self.guard), let f = Address(hex: fallbackHandler), let m = Address(hex: masterCopy) else { return nil }
        return ExistingSafe.OnChain(owners: owners, threshold: UInt64(threshold), modules: modules, guardAddress: g, fallbackHandler: f, singleton: m)
    }
}

// MARK: - 界面文字
//
// 约定（scripts/check-localization.sh 核对）：
// - key 是英文原文，译文在 Localizable.xcstrings，en 和 zh-Hans 都要有；
// - 编译器（SWIFT_EMIT_LOC_STRINGS）从 Text / LocalizedStringKey / String.LocalizationValue 的字面量里抽 key，
//   插值会变成 `%@`、`%lld`，所以可以直接写 `Text("Signed \(n)")`、`L("… \(name) …")`；
// - 不需要翻译的（地址、哈希、数字、设备名）用 `Text(verbatim:)`。

/// 在 String 场景里取译文。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

/// 带参数的译文：key 里写 `%@`、`%lld`。
func F(_ key: String.LocalizationValue, _ args: any CVarArg...) -> String {
    String(format: String(localized: key), arguments: args)
}

enum Display {
    /// 网络名（不带编号），例如 Sepolia。
    static func network(_ id: UInt64) -> String {
        switch id {
        case 1: "Ethereum"
        case 8453: "Base"
        case 11_155_111: "Sepolia"
        default: F("Chain %lld", Int64(id))
        }
    }

    static func isTestnet(_ id: UInt64) -> Bool {
        id == 11_155_111
    }

    /// 区块浏览器里的地址页。
    static func explorerAddress(_ a: Address, chainID: UInt64) -> URL? {
        explorerHost(chainID).flatMap { URL(string: "https://\($0)/address/\(a.checksummed)") }
    }

    /// 项目主页、说明和第三方许可（关于、帮助菜单）。
    static let repository = URL(string: "https://github.com/zhixianio/unipass-inkan")!
    static let readme = URL(string: "https://github.com/zhixianio/unipass-inkan#readme")!
    static let notice = URL(string: "https://github.com/zhixianio/unipass-inkan/blob/main/NOTICE")!

    /// 区块浏览器里的交易页。
    static func explorerTx(_ hash: String, chainID: UInt64) -> URL? {
        explorerHost(chainID).flatMap { URL(string: "https://\($0)/tx/\(hash)") }
    }

    private static func explorerHost(_ chainID: UInt64) -> String? {
        switch chainID {
        case 1: "etherscan.io"
        case 11_155_111: "sepolia.etherscan.io"
        case 8453: "basescan.org"
        default: nil
        }
    }

    /// Safe{Wallet} 里这笔交易的页面。
    static func safeWalletTx(safe: Address, safeTxHash: Data, chainID: UInt64) -> URL? {
        let prefix: String? = switch chainID {
        case 1: "eth"
        case 8453: "base"
        case 11_155_111: "sep"
        default: nil
        }
        guard let prefix else { return nil }
        return URL(string: "https://app.safe.global/transactions/tx?safe=\(prefix):\(safe.checksummed)&id=multisig_\(safe.checksummed)_\(safeTxHash.hexString)")
    }

    static func chain(_ id: UInt64) -> String {
        switch id {
        case 1: "Ethereum (1)"
        case 8453: "Base (8453)"
        case 11_155_111: "Sepolia (11155111)"
        default: F("Chain %lld", Int64(id))
        }
    }
}
