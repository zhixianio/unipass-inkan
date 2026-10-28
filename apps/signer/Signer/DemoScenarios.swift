#if DEBUG
import Foundation
import SignerKit
import UniPassCore

/// 首页的演示 / 调试区块和扫码页的粘贴框：DEBUG 构建里也默认隐藏，启动参数 `-InkanDemo YES` 时才出现。
enum DebugTools {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "InkanDemo") }
}

/// 模拟器演示和截图用的场景（只在 DEBUG 构建里存在）。
/// 启动参数：`-demoScenario green|yellow|red|rejected|ownerChange|registration|firstUse|networkOnline|sendToSigner|ownerLookalike|signerLookalike`。
/// 演示 Safe 用 Sepolia 测试 Safe 的参数（SafeL2 1.4.1、官方 factory），但 owner 换成本机的 signer proxy + 测试 EOA，
/// 地址按 CREATE2 现算：登记时"本机在 owner 里"的检查才能通过。
enum DemoScenario: String, CaseIterable, Identifiable {
    case green, yellow, red, rejected, ownerChange, registration, firstUse, networkOnline, sendToSigner, ownerLookalike, signerLookalike

    var id: String { rawValue }

    static let chain: UInt64 = 11_155_111
    static let testEOA = Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!

    static func testSafe(_ identity: SignerIdentity) -> SafeRegistration {
        var r = SafeRegistration(
            chainID: chain, safe: .zero,
            proxyFactory: Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!,
            singleton: Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!, saltNonce: .zero,
            owners: [identity.signerProxy, testEOA],
            threshold: 2, fallbackHandler: Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!, name: "Test vault")
        r.safe = SafeAddress.compute(r)!
        return r
    }
    static let alice = Address(hex: "0x5a0b54d5dc17e0aadc383d2db43b0a0d3e029c4c")!
    static let stranger = Address(hex: "0x7ce3f2a9c1b4d5e6f708192a3b4c5d6e7f809123")!
    /// 和 alice 首尾各 4 位相同（地址投毒）。
    static let poisoned = Address(hex: "0x5a0b0000000000000000000000000000000e9c4c")!
    static let usdc = Address(hex: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")!
    static let safeMigration = Address(hex: "0x526643F69b81B008F46d95CD5ced5eC0edFFDaC6")!

    func prepare(store: SignerStore, identity: SignerIdentity) {
        let safe = Self.testSafe(identity)
        if self == .registration || self == .firstUse {
            try? store.removeSafe(chainID: safe.chainID, address: safe.safe)
        } else if !store.mySafes.contains(where: { $0.address == safe.safe }) {
            try? store.register(try! SafeAddress.verify(safe, signer: identity.signerProxy), name: "Test vault")
        }
        // ownerLookalike：Test EOA 只是 Safe 的签名人、不在地址簿里，R05 照样要认出仿冒它的地址。
        if self == .ownerLookalike {
            try? store.removeFromAddressBook(Self.testEOA)
        } else if !store.bookEntries.contains(where: { $0.address == Self.testEOA }) {
            try? store.addToAddressBook(Self.testEOA, label: "Test EOA")
        }
        if !store.bookEntries.contains(where: { $0.address == Self.alice }) {
            try? store.addToAddressBook(Self.alice, label: "Alice")
        }
    }

    /// 首尾各 4 位和 `a` 相同、中间全换掉的仿冒地址。
    static func lookalike(of a: Address) -> Address {
        let hex = a.bytes.hexString.dropFirst(2)
        return Address(hex: "0x" + hex.prefix(4) + String(repeating: "0", count: 32) + hex.suffix(4))!
    }

    static func call(_ sig: String, _ types: [ABIType], _ values: [ABIValue]) -> Data {
        Data(Keccak.hash256(Data(sig.utf8)).prefix(4)) + ABICodec.encode(types, values)!
    }

    static func multiSend(_ txs: [(UInt8, Address, UInt256, Data)]) -> Data {
        let packed = txs.reduce(Data()) { $0 + Data([$1.0]) + $1.1.bytes + $1.2.bigEndianBytes + UInt256(UInt64($1.3.count)).bigEndianBytes + $1.3 }
        return Data(Keccak.hash256(Data("multiSend(bytes)".utf8)).prefix(4)) + ABICodec.encode([.bytes], [.bytes(packed)])!
    }

    func ur(identity: SignerIdentity) -> UR? {
        let testSafe = Self.testSafe(identity)
        let safe = testSafe.safe
        let tx: SafeTx
        var safeAddress = safe
        switch self {
        case .registration:
            return testSafe.ur
        case .green, .networkOnline, .firstUse:
            tx = SafeTx(to: Self.usdc, data: Self.call("transfer(address,uint256)", [.address, .uint(256)],
                                                      [.address(Self.alice), .uint(UInt256(25_000_000))]), nonce: UInt256(12))
        case .yellow:
            tx = SafeTx(to: Self.stranger, value: UInt256(50_000_000_000_000_000), nonce: UInt256(13))
        case .red:
            let approve = Self.call("approve(address,uint256)", [.address, .uint(256)],
                                    [.address(Self.poisoned), .uint(UInt256(words: [.max, .max, .max, .max]))])
            // DELEGATECALL 到陌生合约现在直接拒签（R01 只留给 Safe 官方升级库），所以这里用 SafeMigration 1.4.1 演示 R01 红。
            tx = SafeTx(to: Address(hex: "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526")!,
                        data: Self.multiSend([(0, Self.usdc, .zero, approve), (1, Self.safeMigration, .zero, Data())]),
                        operation: .delegateCall, nonce: UInt256(14))
        case .rejected:
            safeAddress = Address(hex: "0x1Db92e2EeBC8E0c075a02BeA49a2935BcD2dFCF4")!
            tx = SafeTx(to: Self.alice, value: UInt256(1), nonce: UInt256(71))
        case .sendToSigner:
            // 把 USDC 转给本机的签名人地址：硬拒（docs/rules.md "转给签名人地址"）。
            tx = SafeTx(to: Self.usdc, data: Self.call("transfer(address,uint256)", [.address, .uint(256)],
                                                      [.address(identity.signerProxy), .uint(UInt256(25_000_000))]), nonce: UInt256(16))
        case .ownerLookalike, .signerLookalike:
            // R05：仿冒 Safe 的另一个签名人 / 本机签名人地址（docs/rules.md R05）。
            let fake = Self.lookalike(of: self == .ownerLookalike ? Self.testEOA : identity.signerProxy)
            tx = SafeTx(to: Self.usdc, data: Self.call("transfer(address,uint256)", [.address, .uint(256)],
                                                      [.address(fake), .uint(UInt256(25_000_000))]), nonce: UInt256(17))
        case .ownerChange:
            tx = SafeTx(to: safe, data: Self.call("swapOwner(address,address,address)", [.address, .address, .address],
                                                  [.address(testSafe.owners[0]), .address(testSafe.owners[1]), .address(Self.stranger)]),
                        nonce: UInt256(15))
        }
        let req = SafeTxRequest(chainID: Self.chain, safe: safeAddress, tx: tx)
        let sign = EthSignRequest(requestID: Data((0..<16).map { UInt8($0) }), signData: Data(req.canonicalJSON.utf8), dataType: .typedData,
                                  chainID: Self.chain, derivationPath: CryptoKeypath(components: [], sourceFingerprint: identity.keyFingerprint),
                                  address: identity.signerProxy, origin: "UniPass Inkan Desktop")
        return self == .firstUse ? SignRequestWithSafe(request: sign, registration: testSafe).ur : sign.ur
    }
}
#endif
