import Foundation
import LocalAuthentication
import Observation
import Security
import SignerKit
import UniPassCore

/// 扫码后进入的流程。
enum Route: Identifiable {
    /// 签名请求：确认页（或拒签页）只消费 RiskAssessment；UR 留着，加入地址簿后重新评估用。
    case confirm(RiskAssessment, UR)
    /// 登记 Safe：已经离线核对过地址，且这台 Signer 在 owner 里。
    /// `then` 是和登记信息一起扫进来的签名请求（S4）：登记后接着评估它。
    case register(SafeAddress.VerifiedSafe, then: EthSignRequest?)
    /// 不能处理的码（类型不对、解析失败、登记核对失败）。
    case failure(String)
    /// 签好的结果，以二维码回传。
    case signature(SignerSignature, safeTxHash: Data)

    var id: String {
        switch self {
        case .confirm(let a, _): "confirm-\(a.request?.safeTxHash.hexString ?? "x")-\(a.findings.count)-\(a.rejections.count)"
        case .register(let v, let then): "register-\(v.registration.safe)-\(then != nil)"
        case .failure(let m): "failure-\(m)"
        case .signature(let s, _): "signature-\(s.signature.r)"
        }
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var key: (any P256SigningKey)?
    private(set) var policy: BiometryPolicy?
    private(set) var keyError: String?
    private(set) var network: NetworkStatus = .online([])
    /// 只用于提示，不影响能不能签：`en0` 上还挂着地址（哪怕只是 fe80::），说明 Wi-Fi 开着、只是没连上网络。
    private(set) var wifiRadioOn = false
    var route: Route?
    var deviceName: String { didSet { UserDefaults.standard.set(deviceName, forKey: "deviceName") } }
    let store: SignerStore
    private let keyStore = KeyStore()

    #if DEBUG
    /// 模拟器和 Mac 共用网络，永远是"联网"；调试时允许忽略。Release 构建里没有这个开关。
    var debugIgnoreNetwork = false
    #endif

    init(store: SignerStore = SignerStore()) {
        self.store = store
        deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? "iPhone"
        network = OfflineCheck.currentStatus()
        #if DEBUG
        // 模拟器演示"读不出签名密钥"：`-demoUnreadableKey YES` 把条目换成读不出的数据。Release 构建里没有。
        if UserDefaults.standard.bool(forKey: "demoUnreadableKey") {
            try? keyStore.delete()
            let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keyStore.service,
                                         kSecAttrAccount: keyStore.account, kSecAttrSynchronizable: false,
                                         kSecValueData: Data([0xEE])]
            SecItemAdd(item as CFDictionary, nil)
        }
        #endif
        loadKey()
    }

    /// 有密钥条目却读不出来（例如锁屏时被预热启动）。这时首页只给"重试"，不给"生成签名密钥"：
    /// 这台 iPhone 可能仍是某个 Safe 的签名人，生成新密钥前必须由用户在设置里明确删除旧的。
    private(set) var keyUnreadable = false

    func loadKey() {
        do {
            let stored = try keyStore.load()
            key = stored?.key
            policy = stored?.policy
            keyError = nil
            keyUnreadable = false
            rememberSignerAddress()
        } catch {
            key = nil
            policy = nil
            keyError = "\(error)"
            keyUnreadable = true
        }
        reloadStore()
    }

    var isOffline: Bool {
        #if DEBUG
        if debugIgnoreNetwork { return true }
        #endif
        return network.isOffline
    }

    var identity: SignerIdentity? { key.map { SignerProxy.identity(key: $0) } }

    var pairing: SignerPairing? { key.map { SignerProxy.pairing(key: $0, name: deviceName, policy: policy) } }

    /// 每秒读一次 getifaddrs（不用 Network 框架）。
    func watchNetwork() async {
        while !Task.isCancelled {
            network = OfflineCheck.currentStatus()
            wifiRadioOn = (try? InterfaceAddress.current())?.contains { $0.name == "en0" } ?? false
            #if DEBUG
            // 截图用：模拟器和 Mac 共用网卡，永远是联网。`-demoOffline YES` 让首页显示离线状态
            // （`-demoWifiOn YES` 再加上"Wi-Fi 开着但没连上"的提示）。只改界面显示；签名时照常重新检查。
            if UserDefaults.standard.bool(forKey: "demoOffline") {
                network = .offline
                wifiRadioOn = UserDefaults.standard.bool(forKey: "demoWifiOn")
            }
            #endif
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func generateKey(policy: BiometryPolicy) {
        do {
            let stored = try keyStore.generate(policy: policy)
            key = stored.key
            self.policy = stored.policy
            keyError = nil
            rememberSignerAddress()
        } catch {
            keyError = "\(error)"
        }
        reloadStore()
    }

    /// 设置页"删除密钥"（两次确认之后）。密钥在安全芯片里，删掉就找不回来；已登记的 Safe 和地址簿保留。
    func deleteKey() {
        do {
            try keyStore.delete()
            keyDeleted()
        } catch {
            keyError = "\(error)"
        }
    }

    /// 设置页"删除读不出的签名密钥"：先过设备密码验证（Face ID 或锁屏密码），防止拿到手机的人随手删掉；
    /// 删之前 KeyStore 再读一次，这时能读出来就不删（`KeyStore.Failure.keyReadable`），并把密钥重新载入。
    /// 只删钥匙串里的这个条目，已登记的 Safe 和地址簿保留。
    func deleteUnreadableKey() async throws {
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                             localizedReason: String(localized: "Delete the signing key that could not be read"))
        do {
            try keyStore.deleteUnreadable()
        } catch KeyStore.Failure.keyReadable {
            loadKey()
            throw KeyStore.Failure.keyReadable
        }
        keyDeleted()
    }

    private func keyDeleted() {
        key = nil
        policy = nil
        keyError = nil
        keyUnreadable = false
        UserDefaults.standard.removeObject(forKey: Self.signerAddressKey)
        reloadStore()
    }

    /// 上次读出的签名人地址。密钥读不出来时算不出地址，删除确认页靠它告诉用户丢的是哪个签名人。
    var lastSignerAddress: Address? { UserDefaults.standard.string(forKey: Self.signerAddressKey).flatMap(Address.init(hex:)) }
    private static let signerAddressKey = "lastSignerAddress"

    private func rememberSignerAddress() {
        guard let identity else { return }
        UserDefaults.standard.set(identity.signerProxy.checksummed, forKey: Self.signerAddressKey)
    }

    // MARK: 扫码

    func context() -> RiskContext {
        RiskContext(mySafes: store.mySafes, addressBook: store.bookEntries, labels: .builtIn,
                    networkOnline: !isOffline, signer: identity)
    }

    func handleScanned(_ ur: UR) {
        switch ur.type {
        case EthSignRequest.urType:
            guard key != nil else {
                route = .failure(String(localized: "Create a signing key first."))
                return
            }
            route = .confirm(RiskEngine(context: context()).assess(ur: ur), ur)
        case SafeRegistration.urType:
            guard let identity else {
                route = .failure(String(localized: "Create a signing key first."))
                return
            }
            do {
                route = .register(try SafeAddress.verify(SafeRegistration(ur: ur), signer: identity.signerProxy), then: nil)
            } catch let e as SafeAddress.VerificationError {
                route = .failure(Self.describe(e))
            } catch {
                route = .failure(String(localized: "The Safe code could not be read."))
            }
        case SignRequestWithSafe.urType:
            guard let identity else {
                route = .failure(String(localized: "Create a signing key first."))
                return
            }
            guard let c = try? SignRequestWithSafe(ur: ur) else {
                route = .failure(String(localized: "The code could not be read."))
                return
            }
            let r = c.registration
            let registered = store.mySafes.contains { $0.chainID == r.chainID && $0.address == r.safe }
            // 只有"没登记过、而且请求签的正是这个 Safe"时才用登记部分；其它情况忽略它，
            // 只看请求本身（没登记的 Safe 照样被规则硬拒）。
            if !registered, c.requestTargetsRegisteredSafe == true {
                do {
                    route = .register(try SafeAddress.verify(r, signer: identity.signerProxy), then: c.request)
                } catch let e as SafeAddress.VerificationError {
                    route = .failure(Self.describe(e))
                } catch {
                    route = .failure(String(localized: "The Safe code could not be read."))
                }
            } else {
                route = .confirm(RiskEngine(context: context()).assess(signRequest: c.request), c.request.ur)
            }
        default:
            route = .failure(String(localized: "This QR code is not a signing request or a Safe code from UniPass Inkan Desktop."))
        }
    }

    static func describe(_ e: SafeAddress.VerificationError) -> String {
        switch e {
        case .unsupportedChain: String(localized: "This network is not supported.")
        case .unknownFactoryOrSingleton: String(localized: "The Safe was not created with an official Safe factory and implementation, so its address cannot be verified offline.")
        case .addressMismatch: String(localized: "The Safe address does not match its creation parameters. Do not register it.")
        case .signerNotAnOwner: String(localized: "This iPhone is not a signer of this Safe, so the Safe cannot be added. Make sure this is the Safe you expect and that this iPhone was added as a signer when it was created.")
        case .setupCall: String(localized: "This Safe ran an extra call while it was being created, which can add modules or signers that are not shown here. It cannot be added.")
        case .setupPayment: String(localized: "This Safe paid someone while it was being created. UniPass Inkan Desktop never creates a Safe this way, so it cannot be added.")
        case .unofficialFallbackHandler: String(localized: "This Safe does not use an official fallback handler. A fallback handler can approve signatures on the Safe's behalf, so it cannot be added.")
        }
    }

    // MARK: 本地数据（我的 Safe、地址簿）

    /// 数据改动后加一，界面靠它刷新（`SignerStore` 本身不是 Observable）。
    private(set) var storeRevision = 0

    var storeStatus: SignerStore.Status {
        _ = storeRevision
        return store.status
    }

    /// 签名密钥变了之后用新的公钥重新验签。
    func reloadStore() {
        store.reload(publicKey: key?.publicKey)
        storeRevision += 1
    }

    /// 改动本地数据要先签名（SE 密钥弹 Face ID）。没有签名密钥就不能改。
    private func localSigner() throws -> LocalDataSigner {
        guard let key else { throw TransactionSigner.Failure.noKey }
        return .faceID(key: key, policy: policy, reason: String(localized: "Save the change to My Safes and the address book"))
    }

    private func changeStore(_ body: (LocalDataSigner) async throws -> Void) async throws {
        defer { storeRevision += 1 }
        try await body(try localSigner())
    }

    /// 确认页上把新地址加入地址簿后，重新评估同一个请求。
    func addToAddressBook(_ address: Address, label: String, reassessing ur: UR?) async throws {
        try await changeStore { try await store.addToAddressBook(address, label: label, signer: $0) }
        if let ur { route = .confirm(RiskEngine(context: context()).assess(ur: ur), ur) }
    }

    /// 登记；带着签名请求时，登记后直接进入这笔交易的确认页。名字由用户在本机输入。
    func register(_ v: SafeAddress.VerifiedSafe, name: String, then request: EthSignRequest?) async throws {
        try await changeStore { try await store.register(v, name: name, signer: $0) }
        if let request {
            route = .confirm(RiskEngine(context: context()).assess(signRequest: request), request.ur)
        } else {
            route = nil
        }
    }

    func removeSafe(_ s: SignerStore.SafeRecord) async throws {
        try await changeStore { try await store.removeSafe(chainID: s.chainID, address: Address(hex: s.address)!, signer: $0) }
    }

    func removeFromAddressBook(_ b: SignerStore.BookRecord) async throws {
        try await changeStore { try await store.removeFromAddressBook(Address(hex: b.address)!, signer: $0) }
    }

    /// 只读的数据：用户看过后用本机当前的密钥签名并开始使用（签名人里没有本机的 Safe 不留）。
    func adoptStoreData() async throws {
        guard let identity else { throw TransactionSigner.Failure.noKey }
        try await changeStore { try await store.adopt(signer: $0, signerAddress: identity.signerProxy) }
    }

    /// 只读的数据：文件改名放到一边（不删除），从空数据开始。先过设备密码验证（Face ID 或锁屏密码）。
    func setAsideStoreData() async throws {
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                             localizedReason: String(localized: "Stop using the saved Safes and address book"))
        defer { storeRevision += 1 }
        try store.setAside()
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case SignerStore.Failure.duplicateSafe: String(localized: "This Safe is already in My Safes.")
        case SignerStore.Failure.duplicateAddress: String(localized: "This address is already in the address book.")
        case SignerStore.Failure.emptyLabel, SignerStore.Failure.emptyName: String(localized: "Enter a name.")
        case SignerStore.Failure.duplicateName: String(localized: "A Safe or an address book entry already has this name. Use a different one.")
        case SignerStore.Failure.readOnly: String(localized: "My Safes and the address book are read-only right now. See the home screen.")
        case TransactionSigner.Failure.noKey: String(localized: "Create a signing key first.")
        default: "\(e)"
        }
    }

    /// Face ID 被取消时不提示错误。
    static func isCancellation(_ e: Error) -> Bool {
        guard let e = e as? LAError else { return false }
        return [.userCancel, .systemCancel, .appCancel].contains(e.code)
    }

    // MARK: 签名

    /// 签名入口只认 SignableTransaction（被拒的 assessment 构造不出来）。
    func sign(_ assessment: RiskAssessment, confirmation: String?) async throws {
        guard let key else { throw TransactionSigner.Failure.noKey }
        let tx = try SignableTransaction(assessment, confirmation: confirmation)
        // 在 Face ID 之后、调 SE 之前读一次当前网络状态（getifaddrs，线程安全；不依赖界面上的轮询结果）。
        #if DEBUG
        let ignore = debugIgnoreNetwork
        #else
        let ignore = false
        #endif
        let offline: @Sendable () -> Bool = { ignore || OfflineCheck.currentStatus().isOffline }
        let sig = try await TransactionSigner.sign(tx, with: key, policy: policy, isOffline: offline,
                                                   authenticate: TransactionSigner.faceID(reason: String(localized: "Approve signing this Safe transaction")))
        route = .signature(sig, safeTxHash: tx.challenge)
    }

    #if DEBUG
    /// 截图和模拟器演示用：直接注入一个场景（只在 DEBUG 构建里存在）。
    func load(demo: DemoScenario) async {
        if key == nil { generateKey(policy: .anyEnrolled) }
        debugIgnoreNetwork = demo != .networkOnline
        let identity = identity!
        try? await changeStore { try await store.change(signer: $0) { demo.prepare(&$0, identity: identity) } }
        if let ur = demo.ur(identity: identity) { handleScanned(ur) }
    }
    #endif
}
