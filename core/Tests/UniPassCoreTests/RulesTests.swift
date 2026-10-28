import Foundation
import Testing
@testable import UniPassCore

/// 规则层测试的公共夹具：一个登记过的 Sepolia Safe、一个测试代币、一个 NFT 合约、一个地址簿条目。
enum Fixture {
    static let chain: UInt64 = 11_155_111
    static let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
    static let usdc = Address(hex: "0x00000000000000000000000000000000000a0001")!
    static let nft = Address(hex: "0x00000000000000000000000000000000000a0002")!
    static let unknownToken = Address(hex: "0x00000000000000000000000000000000000a0003")!
    static let alice = Address(hex: "0x1111111111111111111111111111111111111111")!
    static let stranger = Address(hex: "0x2222222222222222222222222222222222222222")!
    /// 和 alice 首尾各 3 位相同。
    static let aliceLookalike = Address(hex: "0x1119999999999999999999999999999999999111")!
    static let ms141 = Address(hex: "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526")!
    static let callOnly141 = Address(hex: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2")!

    static let library = LabelLibrary(entries: LabelLibrary.builtIn.entries + [
        .init(chainId: chain, address: usdc.checksummed, kind: .erc20, name: "Test USD Coin", symbol: "USDC", decimals: 6, source: "test"),
        .init(chainId: chain, address: nft.checksummed, kind: .erc721, name: "Test NFT", symbol: "TNFT", decimals: nil, source: "test"),
    ])

    static func context(online: Bool = false, safes: [MySafe] = [MySafe(chainID: chain, address: safe, name: "金库")],
                        book: [AddressBookEntry] = [AddressBookEntry(address: alice, label: "Alice")]) -> RiskContext {
        RiskContext(mySafes: safes, addressBook: book, labels: library, networkOnline: online)
    }

    static func call(_ sig: String, _ types: [ABIType], _ values: [ABIValue]) -> Data {
        Data(Keccak.hash256(Data(sig.utf8)).prefix(4)) + ABICodec.encode(types, values)!
    }

    static func assess(to: Address, value: UInt256 = .zero, data: Data = Data(), op: SafeTx.Operation = .call,
                       context: RiskContext = context()) -> RiskAssessment {
        RiskEngine(context: context).assess(SafeTxRequest(chainID: chain, safe: safe,
                                                          tx: SafeTx(to: to, value: value, data: data, operation: op, nonce: UInt256(1))))
    }

    static func multiSend(_ txs: [(UInt8, Address, UInt256, Data)]) -> Data {
        let packed = txs.reduce(Data()) { $0 + Data([$1.0]) + $1.1.bytes + $1.2.bigEndianBytes + UInt256(UInt64($1.3.count)).bigEndianBytes + $1.3 }
        return Selectors.multiSend + ABICodec.encode([.bytes], [.bytes(packed)])!
    }

    static let max256 = UInt256(words: [.max, .max, .max, .max])
}

struct RulesTests {
    typealias F = Fixture

    func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }

    @Test func greenPaths() {
        // 给地址簿里的人转 ETH、转库里的代币、有限授权给地址簿里的人、撤销授权。
        #expect(F.assess(to: F.alice, value: UInt256(1)).verdict == .green)
        let transfer = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(1_500_000))])
        let a = F.assess(to: F.usdc, data: transfer)
        #expect(a.verdict == .green)
        #expect(a.actions[0].explanation.render(.english) == "Send 1.5 USDC to \"Alice\" (0x11111111…11111111) (token contract \"USDC\" (0x00000000…000a0001)).")
        #expect(a.actions[0].explanation.render(.simplifiedChinese) == "向 “Alice” (0x11111111…11111111) 转 1.5 USDC（代币合约 “USDC” (0x00000000…000a0001)）。")
        let approve = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(10))])
        #expect(F.assess(to: F.usdc, data: approve).verdict == .green)
        let revoke = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(.zero)])
        #expect(F.assess(to: F.usdc, data: revoke).verdict == .green)
        // 转给自己的 Safe 也算已知。
        #expect(F.assess(to: F.safe, value: UInt256(1)).verdict == .green)
    }

    @Test func r01DelegateCall() {
        // 陌生合约：硬拒（DelegateCallPolicyTests）；官方升级库 SafeMigration：R01 红。
        #expect(F.assess(to: F.stranger, op: .delegateCall).verdict == .rejected)
        let a = F.assess(to: DelegateCallPolicyTests.safeMigration141, op: .delegateCall)
        #expect(rules(a) == ["R01:red"])
        #expect(a.verdict == .red)
        // 官方 MultiSend 不命中 R01。
        let ms = F.multiSend([(0, F.alice, UInt256(1), Data())])
        #expect(F.assess(to: F.ms141, data: ms, op: .delegateCall).verdict == .green)
        #expect(F.assess(to: F.callOnly141, data: ms, op: .delegateCall).verdict == .green)
        // Safe 官方库里的 SignMessageLib 在 SafeTx 里没有正当用途：硬拒。
        let signMessageLib = Address(hex: "0xd53cd0aB83D845Ac265BE939c57F53AD838012c9")!
        #expect(F.assess(to: signMessageLib, data: Data([1, 2, 3, 4]), op: .delegateCall).verdict == .rejected)
    }

    @Test func r02SafeConfig() {
        let cases: [Data] = [
            F.call("addOwnerWithThreshold(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(2))]),
            F.call("removeOwner(address,address,uint256)", [.address, .address, .uint(256)], [.address(F.alice), .address(F.alice), .uint(UInt256(1))]),
            F.call("swapOwner(address,address,address)", [.address, .address, .address], [.address(F.alice), .address(F.alice), .address(F.alice)]),
            F.call("changeThreshold(uint256)", [.uint(256)], [.uint(UInt256(1))]),
            F.call("enableModule(address)", [.address], [.address(F.alice)]),
            F.call("disableModule(address,address)", [.address, .address], [.address(F.alice), .address(F.alice)]),
            F.call("setGuard(address)", [.address], [.address(.zero)]),
            F.call("setModuleGuard(address)", [.address], [.address(F.alice)]),
            F.call("setFallbackHandler(address)", [.address], [.address(F.alice)]),
            Data(hex: "0xd4d9bdcd")! + Data(count: 32), // approveHash(bytes32)：不认识的 Safe 自身调用
        ]
        for data in cases {
            let a = F.assess(to: F.safe, data: data)
            #expect(rules(a).contains("R02:red"), "\(data.prefix(4).hexString)")
            #expect(a.verdict == .red)
        }
        // 同样的选择器发给别的合约也是 R02：目标可能是另一个 Safe（安全核查 P2-3，见 NestedSafeTests）。
        #expect(rules(F.assess(to: F.stranger, data: cases[3])).contains("R02:red"))
        // 新 owner 是陌生地址时同时命中 R06。
        let addStranger = F.call("addOwnerWithThreshold(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(UInt256(2))])
        #expect(rules(F.assess(to: F.safe, data: addStranger)) == ["R06:yellow", "R02:red"])
    }

    @Test func r03Unlimited() {
        let unlimited = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(F.max256)])
        #expect(rules(F.assess(to: F.usdc, data: unlimited)) == ["R03:red"])
        let justBelow = F.call("approve(address,uint256)", [.address, .uint(256)],
                               [.address(F.alice), .uint(UInt256(999_999_999_999_999))])  // USDC 6 位小数：差 1 到 10 亿个
        #expect(rules(F.assess(to: F.usdc, data: justBelow)) == [])
        let increase = F.call("increaseAllowance(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(F.max256)])
        #expect(rules(F.assess(to: F.usdc, data: increase)) == ["R03:red"])
        let decrease = F.call("decreaseAllowance(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(F.max256)])
        #expect(rules(F.assess(to: F.usdc, data: decrease)) == [])
        let forAll = F.call("setApprovalForAll(address,bool)", [.address, .bool], [.address(F.alice), .bool(true)])
        #expect(rules(F.assess(to: F.nft, data: forAll)) == ["R03:red"])
        let unForAll = F.call("setApprovalForAll(address,bool)", [.address, .bool], [.address(F.stranger), .bool(false)])
        #expect(rules(F.assess(to: F.nft, data: unForAll)) == [])
        let permit2 = F.call("approve(address,address,uint160,uint48)", [.address, .address, .uint(160), .uint(48)],
                             [.address(F.usdc), .address(F.alice), .uint(UInt256(words: [.max, .max, 0xFFFF_FFFF, 0])), .uint(UInt256(1_900_000_000))])
        let p = F.assess(to: SafeDeployments.permit2, data: permit2)
        #expect(rules(p) == ["R03:red"])
        #expect(p.actions[0].explanation.render(.english).contains("2030-03-17 17:46 UTC"))
    }

    @Test func r05Lookalike() {
        let a = F.assess(to: F.aliceLookalike, value: UInt256(1))
        #expect(rules(a) == ["R05:red"])
        #expect(a.findings[0].explanation.render(.simplifiedChinese).contains("“Alice”"))
        // 只有前 3 位相同、后 2 位相同：不算。
        let near = Address(hex: "0x1119999999999999999999999999999999999911")!
        #expect(rules(F.assess(to: near, value: UInt256(1))) == ["R06:yellow"])
        // 大小写不影响比较（EIP-55 只是显示）；和我的 Safe 相似也算。
        let safeLike = Address(hex: "0x8ce" + String(repeating: "0", count: 34) + "4a1")!
        #expect(rules(F.assess(to: safeLike, value: UInt256(1))) == ["R05:red"])
    }

    @Test func r06FirstSeen() {
        #expect(rules(F.assess(to: F.stranger, value: UInt256(1))) == ["R06:yellow"])
        let t = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(UInt256(1))])
        #expect(rules(F.assess(to: F.usdc, data: t)) == ["R06:yellow"])
        // 标签库里的合约不算"首次出现"。
        #expect(rules(F.assess(to: SafeDeployments.permit2, value: UInt256(1))) == [])
    }

    @Test func r07UnknownSelector() {
        let a = F.assess(to: F.stranger, data: Data(hex: "0xdeadbeef")!)
        #expect(rules(a) == ["R07:yellow"])
        #expect(a.verdict == .yellow)
        #expect(rules(F.assess(to: F.stranger, data: Data([1, 2]))) == ["R07:yellow"])
    }

    @Test func r08MultiSendAggregates() {
        let unlimited = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(F.max256)])
        let ms = F.multiSend([(0, F.alice, UInt256(1), Data()), (0, F.usdc, .zero, unlimited), (0, F.stranger, UInt256(1), Data())])
        let a = F.assess(to: F.ms141, data: ms, op: .delegateCall)
        #expect(rules(a) == ["R08:red", "R03:red", "R06:yellow"])
        #expect(a.findings[0].path == [] && a.findings[1].path == [1] && a.findings[2].path == [2])
        #expect(a.actions.map(\.path) == [[], [0], [1], [2]])
        #expect(a.actions[0].level == .red)
        // 子调用只有黄：不加 R08。
        let yellowOnly = F.multiSend([(0, F.stranger, UInt256(1), Data())])
        #expect(rules(F.assess(to: F.ms141, data: yellowOnly, op: .delegateCall)) == ["R06:yellow"])
        // 嵌套的 MultiSend 里的 DELEGATECALL 也会冒泡上来。
        let inner = F.multiSend([(1, DelegateCallPolicyTests.safeMigration141, .zero, Data())])
        let outer = F.multiSend([(1, F.ms141, .zero, inner)])
        #expect(rules(F.assess(to: F.ms141, data: outer, op: .delegateCall)) == ["R08:red", "R08:red", "R01:red"])
    }

    @Test func r09Tokens() {
        let t = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(5))])
        let a = F.assess(to: F.unknownToken, data: t)
        #expect(rules(a) == ["R09:yellow"])
        // 数量单位未知时显示原始整数。
        #expect(a.actions[0].explanation.render(.english).hasPrefix("Send 5 raw units to"))
        // 地址簿把陌生合约叫作 USDC：同名不同地址 → 红。
        let book = [AddressBookEntry(address: F.alice, label: "Alice"), AddressBookEntry(address: F.unknownToken, label: "usdc")]
        #expect(rules(F.assess(to: F.unknownToken, data: t, context: F.context(book: book))) == ["R09:red"])
    }

    @Test func transferFromInterpretation() {
        let tf = F.call("transferFrom(address,address,uint256)", [.address, .address, .uint(256)],
                        [.address(F.safe), .address(F.alice), .uint(UInt256(7_000_000))])
        // 库里的 ERC-20：按数量。
        guard case .tokenTransfer(_, _, _, let amt) = F.assess(to: F.usdc, data: tf).actions[0].kind else { Issue.record("erc20"); return }
        #expect(amt.formatted == "7")
        // 库里的 NFT：按 tokenId。
        guard case .nftTransfer(_, _, _, let id, _) = F.assess(to: F.nft, data: tf).actions[0].kind else { Issue.record("nft"); return }
        #expect(id == UInt256(7_000_000))
        // 不认识的合约：不解释，判黄（R09），说明里提示"未知合约的 transferFrom"。
        let u = F.assess(to: F.unknownToken, data: tf)
        guard case .unknownTransferFrom = u.actions[0].kind else { Issue.record("unknown"); return }
        #expect(rules(u) == ["R09:yellow"])
        #expect(u.actions[0].explanation.render(.simplifiedChinese).hasPrefix("未知合约"))
    }

    @Test func a6AndChainsAreHardRejections() {
        let a = F.assess(to: F.alice, value: UInt256(1), context: F.context(safes: []))
        #expect(a.verdict == .rejected)
        #expect(a.rejections.map(\.reason) == [.safeNotRegistered(chainID: F.chain, safe: F.safe)])
        // 同一地址登记在别的链上也不行。
        let other = F.context(safes: [MySafe(chainID: 1, address: F.safe)])
        #expect(F.assess(to: F.alice, value: UInt256(1), context: other).verdict == .rejected)
        let r = RiskEngine(context: F.context()).assess(SafeTxRequest(chainID: 10, safe: F.safe, tx: SafeTx(to: F.alice, nonce: .zero)))
        #expect(r.rejections.map(\.reason) == [.unsupportedChain(10)])
    }

    @Test func r11NetworkOnlineRejects() {
        let a = F.assess(to: F.alice, value: UInt256(1), context: F.context(online: true))
        #expect(a.rejections.map(\.reason) == [.networkOnline])
        #expect(a.verdict == .rejected)
    }

    /// 每一种解码问题都映射为硬拒。
    @Test func everyDecodingProblemRejects() {
        let a = F.alice
        let bad = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(a), .uint(UInt256(1))]) + Data(count: 32)
        var deep = F.multiSend([(0, a, .zero, Data())])
        for _ in 0..<3 { deep = F.multiSend([(1, F.ms141, .zero, deep)]) }
        let truncated = Selectors.multiSend + ABICodec.encode([.bytes], [.bytes(Data([0]) + a.bytes)])!
        let cases: [(Address, SafeTx.Operation, Data, DecodingProblem)] = [
            (F.usdc, .call, bad, .malformedArguments("transfer(address,uint256)")),
            (F.ms141, .delegateCall, truncated, .malformedMultiSend),
            (F.ms141, .call, F.multiSend([(0, a, .zero, Data())]), .multiSendViaCall),
            (F.ms141, .delegateCall, F.multiSend([(2, a, .zero, Data())]), .invalidInnerOperation(2)),
            (F.callOnly141, .delegateCall, F.multiSend([(1, a, .zero, Data())]), .delegateCallInCallOnly),
            (F.ms141, .delegateCall, deep, .nestingTooDeep),
            (F.ms141, .delegateCall, F.multiSend(Array(repeating: (0, a, .zero, Data()), count: 129)), .tooManyCalls),
        ]
        var covered = Set<String>()
        for (to, op, data, problem) in cases {
            let r = F.assess(to: to, data: data, op: op)
            #expect(r.verdict == .rejected, "\(problem)")
            #expect(r.rejections.contains { if case .decoding(problem, _) = $0.reason { true } else { false } }, "\(problem)")
            #expect(!r.rejections[0].explanation.render(.english).hasPrefix("reject."))
            covered.insert(RiskEngine.problemKey(problem))
        }
        #expect(covered.count == 7)
    }

    @Test func signRequestEntryRejections() throws {
        let engine = RiskEngine(context: F.context())
        let kp = CryptoKeypath(components: [], sourceFingerprint: 1)
        let rawHash = EthSignRequest(requestID: Data(count: 16), signData: Data(count: 32), dataType: .personalMessage, chainID: nil, derivationPath: kp)
        #expect(engine.assess(signRequest: rawHash).rejections.map(\.reason) == [.rawHash])
        let tx = EthSignRequest(requestID: Data(count: 16), signData: Data([0xc0]), dataType: .transaction, chainID: 1, derivationPath: kp)
        #expect(engine.assess(signRequest: tx).rejections.map(\.reason) == [.unsupportedRequest(.transaction)])
        let junk = EthSignRequest(requestID: Data(count: 16), signData: Data("{}".utf8), dataType: .typedData, chainID: 1, derivationPath: kp)
        guard case .malformedRequest = engine.assess(signRequest: junk).rejections.first?.reason else { Issue.record("junk"); return }
        let wrongType = try UR(type: "unipass-safe", value: .map(CBORMap()))
        guard case .malformedRequest = engine.assess(ur: wrongType).rejections.first?.reason else { Issue.record("ur type"); return }
        // 正常请求走通。
        let req = SafeTxRequest(chainID: F.chain, safe: F.safe, tx: SafeTx(to: F.alice, value: UInt256(1), nonce: UInt256(3)))
        let ok = EthSignRequest(requestID: Data(count: 16), signData: Data(req.canonicalJSON.utf8), dataType: .typedData, chainID: F.chain, derivationPath: kp)
        #expect(engine.assess(ur: try UR(parsing: ok.ur.qrString)).verdict == .green)
    }

    @Test func externalStringsAreSanitized() {
        let evil = "Bob\u{202E}evil\u{200B}\n line two that is very very long indeed"
        #expect(Explanation.sanitize(evil) == "Bobevil line two that is very v…")
        let book = [AddressBookEntry(address: F.alice, label: "%@ %1$@ \u{202E}x")]
        let a = F.assess(to: F.alice, value: UInt256(1), context: F.context(book: book))
        #expect(a.actions[0].explanation.render(.english) == "Send 0.000000000000000001 ETH to \"%@ %1$@ x\" (0x11111111…11111111).")
    }

    @Test func amountsFormat() {
        #expect(TokenAmount(raw: UInt256(1_234_567_890_000), decimals: 6, symbol: nil).formatted == "1,234,567.89")
        #expect(TokenAmount(raw: UInt256(5), decimals: 18, symbol: nil).formatted == "0.000000000000000005")
        #expect(TokenAmount(raw: .zero, decimals: 6, symbol: nil).formatted == "0")
        #expect(TokenAmount(raw: UInt256(1_000_000), decimals: nil, symbol: nil).formatted == "1,000,000")
    }
}

/// 模板：源码里用到的每个 key 都在 String Catalog 里，中英都有，渲染后不残留占位符。
struct ExplanationCatalogTests {
    static func usedKeys() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var keys = Set<String>()
        for f in ["RiskEngine.swift", "Explanation.swift"] {
            let src = try String(decoding: FileManager.default.contents(atPath: root.appending(path: "Sources/UniPassCore/Rules/\(f)").path) ?? Data(), as: UTF8.self)
            let re = try Regex(#""((?:action|rule|reject|amount|timestamp|gas)\.[A-Za-z0-9.]+)""#)
            for m in src.matches(of: re) { keys.insert(String(m.output[1].substring!)) }
        }
        return keys
    }

    static func catalog() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = FileManager.default.contents(atPath: root.appending(path: "Sources/UniPassCore/Resources/Localizable.xcstrings").path)!
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["strings"] as! [String: Any]
    }

    @Test func everyKeyTranslated() throws {
        let used = try Self.usedKeys()
        let catalog = try Self.catalog()
        #expect(used.count > 50)
        for key in used {
            #expect(catalog[key] != nil, "missing \(key)")
            for lang in Explanation.Language.allCases {
                let e = Explanation(key, .plain("A"), .plain("B"), .plain("C"), .plain("D"), .plain("E"))
                let s = e.render(lang)
                #expect(s != key && !s.contains("%"), "\(key) [\(lang)] → \(s)")
            }
        }
        // 目录里没有源码不用的 key。
        #expect(Set(catalog.keys).subtracting(used).isEmpty, "\(Set(catalog.keys).subtracting(used))")
    }
}

struct LabelLibraryTests {
    @Test func builtInIsWellFormed() {
        let lib = LabelLibrary.builtIn
        #expect(lib.entries.count >= 132)
        for e in lib.entries {
            #expect(e.parsedAddress != nil, "\(e.address)")
            #expect(SafeDeployments.supportedChains.contains(e.chainId))
            #expect(!e.source.isEmpty)
            if e.kind == .erc20 { #expect(e.symbol != nil) }
        }
        // 每个 MultiSend 都在库里。
        for chain in SafeDeployments.supportedChains {
            for m in SafeDeployments.multiSendContracts {
                #expect(lib.lookup(chainID: chain, address: m.address)?.kind == .safeLibrary)
            }
            #expect(lib.lookup(chainID: chain, address: SafeDeployments.permit2)?.kind == .permit2)
        }
    }
}

/// Bybit（2025-02-21）重放：只用公开事后分析里的交易结构（testvectors/rules/bybit-2025-02-21.json，出处在文件里）。
struct BybitReplayTests {
    struct Vector: Decodable {
        struct Tx: Decodable { let to, value, data: String; let operation: UInt8; let safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, nonce: String }
        let safe: String
        let chainId: UInt64
        let tx: Tx
        let safeTxHashOnChain: String
    }

    static let v = try! loadVectors(Vector.self, "rules/bybit-2025-02-21.json")

    static var request: SafeTxRequest {
        let t = v.tx
        return SafeTxRequest(chainID: v.chainId, safe: Address(hex: v.safe)!, tx: SafeTx(
            to: Address(hex: t.to)!, value: UInt256(decimal: t.value)!, data: Data(hex: t.data)!,
            operation: SafeTx.Operation(rawValue: t.operation)!, safeTxGas: UInt256(decimal: t.safeTxGas)!,
            baseGas: UInt256(decimal: t.baseGas)!, gasPrice: UInt256(decimal: t.gasPrice)!,
            gasToken: Address(hex: t.gasToken)!, refundReceiver: Address(hex: t.refundReceiver)!, nonce: UInt256(decimal: t.nonce)!))
    }

    /// 就算这个 Safe 登记在"我的 Safe"里、地址簿是空的，也硬拒：DELEGATECALL 到陌生合约，没有越过的入口。
    @Test func rejectedForDelegateCall() {
        let ctx = RiskContext(mySafes: [MySafe(chainID: 1, address: Address(hex: Self.v.safe)!)], addressBook: [])
        let a = RiskEngine(context: ctx).assess(Self.request)
        #expect(a.verdict == .rejected)
        #expect(a.rejections.map(\.reason) == [.delegateCallNotAllowed(Address(hex: "0x96221423681A6d52E184D440a8eFCEbB105C7242")!)])
        #expect(a.rejections[0].explanation.render(.english).hasPrefix("DELEGATECALL to 0x96221423…105C7242"))
        // 真实交易的 safeTxGas 是 45746（退款字段都为空，不触发退款硬拒），所以另有一条 R12 黄。
        #expect(a.findings.contains { $0.rule == .R12 && $0.level == .yellow })
        // 表面上是"转 0 个代币"，说明必须先讲 DELEGATECALL。
        guard case .tokenTransfer(_, _, let to, let amt) = a.actions[0].kind else { Issue.record("kind"); return }
        #expect(to.address == Address(hex: "0xbDd077f651EBe7f7b3cE16fe5F2b025BE2969516")! && amt.raw.isZero)
        #expect(a.actions[0].operation == .delegateCall)
        #expect(a.actions[0].explanation.render(.english).hasPrefix("DELEGATECALL: this Safe will run the code of 0x96221423…105C7242 as itself."))
        #expect(a.actions[0].explanation.render(.simplifiedChinese).hasPrefix("DELEGATECALL：这个 Safe 会以自己的身份运行 0x96221423…105C7242 的代码。"))
    }

    /// Safe 没登记时直接硬拒。
    @Test func unregisteredSafeRejected() {
        let a = RiskEngine(context: RiskContext(mySafes: [])).assess(Self.request)
        #expect(a.verdict == .rejected)
    }

    /// Bybit 的签名人签的是裸哈希（ETH_SIGN）。同样的请求到了 Signer 直接硬拒。
    @Test func bareHashSigningRejected() {
        let req = EthSignRequest(requestID: Data(count: 16), signData: Data(hex: Self.v.safeTxHashOnChain)!, dataType: .personalMessage,
                                 chainID: 1, derivationPath: CryptoKeypath(components: [], sourceFingerprint: 1))
        let ctx = RiskContext(mySafes: [MySafe(chainID: 1, address: Address(hex: Self.v.safe)!)])
        #expect(RiskEngine(context: ctx).assess(signRequest: req).rejections.map(\.reason) == [.rawHash])
    }
}

struct BuiltInTokenTests {
    @Test func realTokens() {
        let lib = LabelLibrary.builtIn
        let usdc = lib.lookup(chainID: 1, address: Address(hex: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")!)
        #expect(usdc?.symbol == "USDC" && usdc?.decimals == 6 && usdc?.kind == .erc20)
        #expect(lib.lookup(chainID: 8453, address: Address(hex: "0x4200000000000000000000000000000000000006")!)?.symbol == "WETH")
        #expect(lib.entries.filter(\.isToken).count == 27)
        #expect(lib.entries.filter(\.isToken).allSatisfy { $0.decimals != nil && $0.source.contains("https://") })
        // 同一地址在别的链上不认。
        #expect(lib.lookup(chainID: 8453, address: Address(hex: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")!) == nil)
    }

    @Test func mainnetUSDCTransferIsGreen() {
        let safe = Fixture.safe
        let usdc = Address(hex: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")!
        let data = Fixture.call("transfer(address,uint256)", [.address, .uint(256)], [.address(Fixture.alice), .uint(UInt256(250_000_000))])
        let ctx = RiskContext(mySafes: [MySafe(chainID: 1, address: safe)], addressBook: [AddressBookEntry(address: Fixture.alice, label: "Alice")])
        let a = RiskEngine(context: ctx).assess(SafeTxRequest(chainID: 1, safe: safe, tx: SafeTx(to: usdc, data: data, nonce: .zero)))
        #expect(a.verdict == .green)
        #expect(a.actions[0].explanation.render(.english).hasPrefix("Send 250 USDC to \"Alice\""))
    }
}

/// SafeTx 的 gas / 退款字段：退款一律硬拒，safeTxGas 不为 0 判黄（R12）。语义见 docs/rules.md "gas 与退款"。
struct GasRefundTests {
    typealias F = Fixture

    static let transfer = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(25_000_000))])
    static let attacker = Address(hex: "0x00000000000000000000000000000000000000ee")!

    static func assess(safeTxGas: UInt256 = .zero, baseGas: UInt256 = .zero, gasPrice: UInt256 = .zero,
                       gasToken: Address = .zero, refundReceiver: Address = .zero, data: Data = transfer, to: Address = F.usdc) -> RiskAssessment {
        RiskEngine(context: F.context()).assess(SafeTxRequest(chainID: F.chain, safe: F.safe, tx: SafeTx(
            to: to, data: data, safeTxGas: safeTxGas, baseGas: baseGas, gasPrice: gasPrice,
            gasToken: gasToken, refundReceiver: refundReceiver, nonce: UInt256(1))))
    }

    static func refundRejected(_ a: RiskAssessment) -> Bool {
        a.verdict == .rejected && a.rejections.contains { if case .gasRefundNotSupported = $0.reason { true } else { false } }
    }

    @Test func noRefundFieldsIsGreen() {
        let a = Self.assess()
        #expect(a.verdict == .green && a.rejections.isEmpty && a.findings.isEmpty)
    }

    /// 攻击场景：界面上是"转 25 USDC 给 Alice"（绿），但 gasPrice、baseGas 很大，退款收给攻击者。
    @Test func refundToAttackerIsRejected() throws {
        let a = Self.assess(baseGas: UInt256(10_000_000), gasPrice: UInt256(1_000_000_000_000), refundReceiver: Self.attacker)
        #expect(a.actions.allSatisfy { $0.level == .green })
        #expect(Self.refundRejected(a))
        #expect(a.rejections.map(\.reason) == [.gasRefundNotSupported(gasPrice: UInt256(1_000_000_000_000), baseGas: UInt256(10_000_000),
                                                                        gasToken: .zero, refundReceiver: Self.attacker)])
        #expect(throws: SignableTransaction.Refusal.self) { try SignableTransaction(Self.withID(a)) }
        let r = a.rejections[0].explanation
        #expect(r.render(.english) == "This transaction uses the Safe gas refund (gasPrice 1000000000000, baseGas 10000000, paid in ETH to 0x00000000…000000eE). When it is executed, the Safe would pay that refund from its own balance, on top of what this transaction shows. UniPass Inkan does not use refunds, so it is refused.")
        #expect(r.render(.simplifiedChinese) == "这笔交易用了 Safe 的 gas 退款（gasPrice 1000000000000，baseGas 10000000，退款币种 ETH，收款方 0x00000000…000000eE）。执行时 Safe 会在这笔交易显示的内容之外，再从自己的余额里付这笔“退款”。UniPass Inkan 不使用退款，所以拒签。")
    }

    /// 四个字段任何一个不是默认值都拒绝；gasPrice 为 0 时合约不会付款，但也不接受。
    @Test func eachRefundFieldAloneIsRejected() {
        #expect(Self.refundRejected(Self.assess(gasPrice: UInt256(1))))
        #expect(Self.refundRejected(Self.assess(baseGas: UInt256(1))))
        #expect(Self.refundRejected(Self.assess(gasToken: F.usdc)))
        #expect(Self.refundRejected(Self.assess(refundReceiver: Self.attacker)))
        // 零地址的退款接收方是"提交交易的账户"（tx.origin），用代币付时显示代币地址。
        let a = Self.assess(gasPrice: UInt256(5), gasToken: F.usdc)
        #expect(a.rejections[0].explanation.render(.english).contains("paid in 0x00000000…000a0001 to whoever submits the transaction"))
        #expect(a.rejections[0].explanation.render(.simplifiedChinese).contains("退款币种 0x00000000…000a0001，收款方 提交这笔交易的账户"))
    }

    /// 被拒的请求就算是红色也不能越过；退款拒绝和"Safe 没登记"等其它拒绝可以同时出现。
    @Test func refundRejectionCombinesWithOthers() {
        let ctx = F.context(safes: [])
        let a = RiskEngine(context: ctx).assess(SafeTxRequest(chainID: F.chain, safe: F.safe, tx: SafeTx(
            to: F.alice, value: UInt256(1), gasPrice: UInt256(1), nonce: .zero)))
        #expect(a.rejections.count == 2 && a.verdict == .rejected)
    }

    /// safeTxGas 不为 0：判黄（R12），不硬拒；本来是红的仍然是红，确认短语不多出一项。
    @Test func safeTxGasIsYellow() throws {
        let a = Self.assess(safeTxGas: UInt256(50_000))
        #expect(a.rejections.isEmpty && a.verdict == .yellow)
        #expect(a.findings.map(\.rule) == [.R12] && a.findings[0].path == [])
        #expect(a.findings[0].explanation.render(.english).hasPrefix("R12 This transaction sets safeTxGas to 50000. If it fails when executed, it is still recorded as done"))
        #expect(a.findings[0].explanation.render(.simplifiedChinese).hasPrefix("R12 这笔交易把 safeTxGas 设成了 50000。执行失败时它仍会被记为已执行"))
        _ = try SignableTransaction(Self.withID(a))

        let approve = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(F.max256)])
        let red = Self.assess(safeTxGas: UInt256(50_000), data: approve)
        #expect(red.verdict == .red)
        #expect(ConfirmationPhrase(red).tokens.map(\.rule) == [.R03])
    }

    static func withID(_ a: RiskAssessment) -> RiskAssessment {
        var a = a
        a.requestID = Data(count: 16)
        return a
    }
}

/// 收款方是这台 Signer 自己的 signer proxy：硬拒。它只是签名人合约，没有提款功能，转进去就取不回来。
struct SignerAddressTests {
    typealias F = Fixture

    static let me = SignerIdentity(keyFingerprint: 0x7A6D_6628, signerProxy: Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!)

    static func context() -> RiskContext {
        RiskContext(mySafes: [MySafe(chainID: F.chain, address: F.safe, name: "金库")],
                    addressBook: [AddressBookEntry(address: F.alice, label: "Alice")],
                    labels: F.library, networkOnline: false, signer: me)
    }

    static func assess(to: Address, value: UInt256 = .zero, data: Data = Data(), op: SafeTx.Operation = .call) -> RiskAssessment {
        F.assess(to: to, value: value, data: data, op: op, context: context())
    }

    static func rejected(_ a: RiskAssessment) -> Bool {
        a.verdict == .rejected && a.rejections.map(\.reason) == [.sendsToSignerAddress]
    }

    @Test func ethToSignerIsRejected() {
        let a = Self.assess(to: Self.me.signerProxy, value: UInt256(1))
        #expect(Self.rejected(a))
        #expect(a.rejections[0].explanation.render(.simplifiedChinese) == "收款地址是这台签名器自己的签名合约，它不能收款，转进去的资产会永久取不回来。")
        #expect(a.rejections[0].explanation.render(.english) == "The recipient is this iPhone's own signer contract. It cannot receive funds: anything sent to it is lost for good.")
    }

    @Test func erc20ToSignerIsRejected() {
        let transfer = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(Self.me.signerProxy), .uint(UInt256(1_000_000))])
        #expect(Self.rejected(Self.assess(to: F.usdc, data: transfer)))
        let transferFrom = F.call("transferFrom(address,address,uint256)", [.address, .address, .uint(256)],
                                  [.address(F.safe), .address(Self.me.signerProxy), .uint(UInt256(1_000_000))])
        #expect(Self.rejected(Self.assess(to: F.usdc, data: transferFrom)))
    }

    /// MultiSend 里只要有一条转给它就整笔拒绝，拒签原因只出现一次。
    @Test func innerCallToSignerIsRejected() {
        let toAlice = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(1))])
        let toMe = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(Self.me.signerProxy), .uint(UInt256(1))])
        let data = F.multiSend([(0, F.usdc, .zero, toAlice), (0, F.usdc, .zero, toMe), (0, Self.me.signerProxy, UInt256(5), Data())])
        let a = Self.assess(to: F.callOnly141, data: data, op: .delegateCall)
        #expect(Self.rejected(a))
    }

    /// 收款方是别的地址照常放行；没有 signer 身份时（例如桌面端预览）不做这项检查。
    @Test func otherRecipientsAreUnaffected() {
        let transfer = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(UInt256(1_500_000))])
        #expect(Self.assess(to: F.usdc, data: transfer).verdict == .green)
        #expect(Self.assess(to: F.alice, value: UInt256(1)).verdict == .green)
        #expect(F.assess(to: Self.me.signerProxy, value: UInt256(1)).rejections.isEmpty)
    }
}

/// R05 也和已登记 Safe 的签名人（`MySafe.owners`）、本机签名人地址比对：登记时就知道这些地址，不在地址簿里也一样。
struct SafeOwnerLookalikeTests {
    typealias F = Fixture

    static let me = SignerAddressTests.me
    static let bob = Address(hex: "0x9383" + String(repeating: "0", count: 30) + "aab39a")!
    /// 和 bob 首尾各 3 位相同。
    static let bobLookalike = Address(hex: "0x938" + String(repeating: "5", count: 34) + "39a")!
    static let meLookalike = Address(hex: "0xc8f" + String(repeating: "7", count: 34) + "a06")!

    static func context(book: [AddressBookEntry] = [AddressBookEntry(address: F.alice, label: "Alice")]) -> RiskContext {
        RiskContext(mySafes: [MySafe(chainID: F.chain, address: F.safe, name: "My Safe", owners: [me.signerProxy, bob], threshold: 2)],
                    addressBook: book, labels: F.library, networkOnline: false, signer: me)
    }

    static func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }

    /// 不在地址簿里、只在 owners 里：判红，说明写清楚是哪个 Safe 的签名人。
    @Test func ownerOnlyIsRed() {
        let a = F.assess(to: Self.bobLookalike, value: UInt256(1), context: Self.context())
        #expect(Self.rules(a) == ["R05:red"])
        #expect(a.findings[0].subject == .lookalike(Self.bobLookalike, similarTo: Self.bob))
        let fake = Explanation.shortAddress(Self.bobLookalike), real = Explanation.shortAddress(Self.bob)
        #expect(a.findings[0].explanation.render(.simplifiedChinese)
                == "R05 \(fake) 看起来像 Safe “My Safe” 的签名人 \(real)（首尾几位相同），但不是同一个地址。地址投毒就是这样骗人的。")
        #expect(a.findings[0].explanation.render(.english)
                == "R05 \(fake) looks like \(real), a signer of the Safe \"My Safe\" (same first and last characters), but is a different address. This is how address poisoning works.")
        // ERC-20 收款人一样。
        let transfer = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(Self.bobLookalike), .uint(UInt256(1))])
        #expect(Self.rules(F.assess(to: F.usdc, data: transfer, context: Self.context())) == ["R05:red"])
    }

    /// Safe 没起名字时写 Safe 的短地址。
    @Test func unnamedSafeShowsAddress() {
        var c = Self.context()
        c.mySafes[0].name = nil
        let a = F.assess(to: Self.bobLookalike, value: UInt256(1), context: c)
        #expect(a.findings[0].explanation.render(.simplifiedChinese).contains("Safe \(Explanation.shortAddress(F.safe)) 的签名人"))
    }

    /// 长得像本机签名人地址：判红（不是同一个地址，所以不触发"转给签名人地址"的硬拒）。
    @Test func thisSignerLookalikeIsRed() {
        let a = F.assess(to: Self.meLookalike, value: UInt256(1), context: Self.context())
        #expect(Self.rules(a) == ["R05:red"])
        #expect(a.rejections.isEmpty)
        #expect(a.findings[0].subject == .lookalike(Self.meLookalike, similarTo: Self.me.signerProxy))
        #expect(a.findings[0].explanation.render(.simplifiedChinese).contains("看起来像本机的签名人地址 \(Explanation.shortAddress(Self.me.signerProxy))"))
    }

    /// 地址簿和 owners 里都有：只报一次，用地址簿里的名字。
    @Test func bookAndOwnerReportedOnce() {
        let a = F.assess(to: Self.bobLookalike, value: UInt256(1),
                         context: Self.context(book: [AddressBookEntry(address: Self.bob, label: "Bob")]))
        #expect(Self.rules(a) == ["R05:red"])
        #expect(a.findings[0].explanation.key == "rule.R05")
        #expect(a.findings[0].explanation.render(.simplifiedChinese).contains("“Bob”"))
    }

    /// 完全不相似的地址不受影响；签名人本人也不算"相似"。
    @Test func unrelatedAddressesUnaffected() {
        #expect(Self.rules(F.assess(to: F.stranger, value: UInt256(1), context: Self.context())) == ["R06:yellow"])
        #expect(Self.rules(F.assess(to: F.alice, value: UInt256(1), context: Self.context())) == [])
        #expect(!Self.rules(F.assess(to: Self.bob, value: UInt256(1), context: Self.context())).contains("R05:red"))
    }
}

/// 命中 R05 的对方地址不标"首次出现"、不提供"加入地址簿"；普通新地址照旧。
struct FirstSeenTests {
    typealias F = Fixture

    /// 每条调用的对方地址（收款人 / 授权对象 / operator），按调用顺序。
    static func counterparties(_ a: RiskAssessment) -> [AddressInfo] {
        a.actions.compactMap { act in
            switch act.kind {
            case .nativeTransfer(let to, _), .tokenTransfer(_, _, let to, _), .nftTransfer(_, _, let to, _, _), .unknownTransferFrom(_, _, let to, _): to
            case .approval(_, let s, _, _), .allowanceChange(_, let s, _, _, _), .permit2Approval(_, let s, _, _, _): s
            case .approvalForAll(_, let o, _): o
            default: nil
            }
        }
    }

    @Test func lookalikeIsNotFirstSeen() {
        let eth = F.assess(to: F.aliceLookalike, value: UInt256(1))
        #expect(eth.lookalikeAddresses == [F.aliceLookalike])
        #expect(Self.counterparties(eth).map { eth.isFirstSeen($0) } == [false])
        let transfer = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.aliceLookalike), .uint(UInt256(1))])
        let erc20 = F.assess(to: F.usdc, data: transfer)
        #expect(Self.counterparties(erc20).map { erc20.isFirstSeen($0) } == [false])
        let nft = F.call("safeTransferFrom(address,address,uint256)", [.address, .address, .uint(256)],
                         [.address(F.safe), .address(F.aliceLookalike), .uint(UInt256(7))])
        let n = F.assess(to: F.nft, data: nft)
        #expect(Self.counterparties(n).map { n.isFirstSeen($0) } == [false])
    }

    /// 普通新地址仍然标"首次出现"；认识的地址和本机签名人地址不标。
    @Test func strangerIsFirstSeen() {
        let a = F.assess(to: F.stranger, value: UInt256(1))
        #expect(a.lookalikeAddresses.isEmpty)
        #expect(Self.counterparties(a).map { a.isFirstSeen($0) } == [true])
        let known = F.assess(to: F.alice, value: UInt256(1))
        #expect(Self.counterparties(known).map { known.isFirstSeen($0) } == [false])
        let me = SignerAddressTests.me.signerProxy
        let toMe = F.assess(to: me, value: UInt256(1))
        #expect(Self.counterparties(toMe).map { toMe.isFirstSeen($0, thisSigner: me) } == [false])
    }

    /// MultiSend 内层：仿冒地址不标，同一笔里的普通新地址照旧标。
    @Test func multiSendInnerCalls() {
        let toFake = F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(F.aliceLookalike), .uint(UInt256(1))])
        let approveStranger = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(UInt256(5))])
        let a = F.assess(to: F.callOnly141, data: F.multiSend([(0, F.usdc, .zero, toFake), (0, F.usdc, .zero, approveStranger)]), op: .delegateCall)
        let c = Self.counterparties(a)
        #expect(c.map(\.address) == [F.aliceLookalike, F.stranger])
        #expect(c.map { a.isFirstSeen($0) } == [false, true])
    }

    /// 仿冒 Safe 签名人的地址也一样。
    @Test func safeOwnerLookalikeIsNotFirstSeen() {
        let a = F.assess(to: SafeOwnerLookalikeTests.bobLookalike, value: UInt256(1), context: SafeOwnerLookalikeTests.context())
        #expect(Self.counterparties(a).map { a.isFirstSeen($0) } == [false])
    }
}

/// 安全核查 P0-2：标签库里的地址不算"认识的对方"。MultiSendCallOnly 等 Safe 库合约谁都能 CALL，
/// 授权或转给它们的资产任何人都能取走；转给代币合约本身通常就是丢了。
struct CounterpartyTrustTests {
    typealias F = Fixture

    static let msco141 = Address(hex: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2")!
    static let msco150 = Address(hex: "0xA83c336B20401Af773B6219BA5027174338D1836")!
    static let singleton141L2 = Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!
    static let signerFactory = Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!
    static let e30 = UInt256(words: [0x4674edea40000000, 0xc9f2c9cd0, 0, 0])

    static func approve(_ s: Address, _ n: UInt256) -> Data { F.call("approve(address,uint256)", [.address, .uint(256)], [.address(s), .uint(n)]) }
    static func transfer(_ to: Address, _ n: UInt256) -> Data { F.call("transfer(address,uint256)", [.address, .uint(256)], [.address(to), .uint(n)]) }
    static func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }

    /// Safe 库合约、singleton、factory、fallback handler、signer factory 当对方：硬拒。
    @Test func safeContractsAsCounterpartyAreRejected() {
        let tf = F.call("transferFrom(address,address,uint256)", [.address, .address, .uint(256)],
                        [.address(F.safe), .address(Self.msco150), .uint(UInt256(42))])
        let p2 = F.call("approve(address,address,uint160,uint48)", [.address, .address, .uint(160), .uint(48)],
                        [.address(F.usdc), .address(Self.msco141), .uint(Self.e30), .uint(UInt256(1_900_000_000))])
        let add = F.call("addOwnerWithThreshold(address,uint256)", [.address, .uint(256)], [.address(Self.msco141), .uint(UInt256(1))])
        let cases: [RiskAssessment] = [
            F.assess(to: F.usdc, data: Self.approve(Self.msco141, Self.e30)),
            F.assess(to: F.usdc, data: Self.transfer(Self.msco141, UInt256(1_000_000))),
            F.assess(to: F.nft, data: tf),
            F.assess(to: SafeDeployments.permit2, data: p2),
            F.assess(to: F.ms141, data: F.multiSend([(0, F.usdc, .zero, Self.approve(Self.msco141, Self.e30))]), op: .delegateCall),
            F.assess(to: F.safe, data: add),
            F.assess(to: Self.msco141, value: UInt256(1)),
            F.assess(to: F.usdc, data: Self.transfer(Self.singleton141L2, UInt256(1))),
            F.assess(to: F.usdc, data: Self.approve(Self.signerFactory, UInt256(1))),
            F.assess(to: F.usdc, data: Self.transfer(SafeDeployments.permit2, UInt256(1))),
        ]
        for (i, a) in cases.enumerated() {
            #expect(a.verdict == .rejected && a.rejections.allSatisfy {
                if case .counterpartyIsSafeContract = $0.reason { true } else { false }
            }, "case \(i): \(a.rejections.map(\.reason))")
            // 不提供"加入地址簿"。
            #expect(a.actions.flatMap { RiskEngine.counterparties($0.kind, target: nil) }.allSatisfy { !a.isFirstSeen($0) })
        }
    }

    /// Permit2 只在"ERC-20 approve 给 Permit2"时算认识的对方。
    @Test func approveToPermit2IsKnown() {
        let a = F.assess(to: F.usdc, data: Self.approve(SafeDeployments.permit2, UInt256(1_000_000)))
        #expect(a.verdict == .green, "\(Self.rules(a))")
    }

    /// 代币合约本身当对方：判红。
    @Test func tokenContractAsCounterpartyIsRed() {
        let toSelf = F.assess(to: F.usdc, data: Self.transfer(F.usdc, UInt256(1)))
        #expect(toSelf.verdict == .red && Self.rules(toSelf).contains("R13:red"), "\(Self.rules(toSelf))")
        let toNFT = F.assess(to: F.usdc, data: Self.approve(F.nft, UInt256(1)))
        #expect(toNFT.verdict == .red && Self.rules(toNFT).contains("R13:red"), "\(Self.rules(toNFT))")
        // 不在库里的代币合约，收款方就是它自己。
        let unknownSelf = F.assess(to: F.unknownToken, data: Self.transfer(F.unknownToken, UInt256(1)))
        #expect(Self.rules(unknownSelf).contains("R13:red"), "\(Self.rules(unknownSelf))")
    }
}

/// 安全核查 P1-1：代币的"别名函数"要和标准函数一样走 R03、R05 和"转给签名人地址"的硬拒；
/// 对库里的代币合约调用不认识的函数直接判红。
struct TokenAliasTests {
    typealias F = Fixture
    static let me = SignerAddressTests.me
    static let dai = Address(hex: "0x6B175474E89094C44Da98b954EedeAC495271d0F")!

    static func ctx(chain: UInt64 = F.chain) -> RiskContext {
        RiskContext(mySafes: [MySafe(chainID: chain, address: F.safe, name: "S")],
                    addressBook: [AddressBookEntry(address: F.alice, label: "Alice")], labels: F.library, signer: me)
    }
    static func assess(_ to: Address, _ data: Data, chain: UInt64 = F.chain) -> RiskAssessment {
        RiskEngine(context: ctx(chain: chain)).assess(SafeTxRequest(chainID: chain, safe: F.safe,
                                                                    tx: SafeTx(to: to, data: data, nonce: UInt256(1))))
    }
    static func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }
    static func toSigner(_ a: RiskAssessment) -> Bool { a.rejections.map(\.reason) == [.sendsToSignerAddress] }
    static func call(_ sig: String, _ types: [ABIType], _ values: [ABIValue]) -> Data { F.call(sig, types, values) }

    @Test func unknownSelectorOnLibraryTokenIsRed() {
        let a = Self.assess(F.usdc, Data(hex: "0xdeadbeef")! + Data(count: 32))
        #expect(a.verdict == .red, "\(Self.rules(a))")
        // 不在库里的合约照旧判黄。
        #expect(Self.assess(F.unknownToken, Data(hex: "0xdeadbeef")!).verdict == .yellow)
    }

    @Test func approvalAliases() {
        let inc = Self.call("increaseApproval(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(F.max256)])
        #expect(Self.rules(Self.assess(F.usdc, inc)).contains("R03:red"), "\(Self.rules(Self.assess(F.usdc, inc)))")
        let dec = Self.call("decreaseApproval(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(UInt256(1))])
        #expect(Self.assess(F.usdc, dec).verdict == .green, "\(Self.rules(Self.assess(F.usdc, dec)))")
        for sig in ["approveAndCall(address,uint256)", "approveAndCall(address,uint256,bytes)"] {
            let types: [ABIType] = sig.hasSuffix("bytes)") ? [.address, .uint(256), .bytes] : [.address, .uint(256)]
            let vals: [ABIValue] = [.address(F.stranger), .uint(F.max256)] + (types.count == 3 ? [.bytes(Data())] : [])
            #expect(Self.rules(Self.assess(F.usdc, Self.call(sig, types, vals))).contains("R03:red"), "\(sig)")
        }
        let op = Self.call("authorizeOperator(address)", [.address], [.address(F.stranger)])
        #expect(Self.rules(Self.assess(F.unknownToken, op)).contains("R03:red"))
    }

    @Test func transferAliases() {
        let tac3 = { (to: Address) in Self.call("transferAndCall(address,uint256,bytes)", [.address, .uint(256), .bytes], [.address(to), .uint(UInt256(1)), .bytes(Data())]) }
        let tac2 = { (to: Address) in Self.call("transferAndCall(address,uint256)", [.address, .uint(256)], [.address(to), .uint(UInt256(1))]) }
        let shares = { (to: Address) in Self.call("transferShares(address,uint256)", [.address, .uint(256)], [.address(to), .uint(UInt256(1))]) }
        let sharesFrom = { (to: Address) in Self.call("transferSharesFrom(address,address,uint256)", [.address, .address, .uint(256)], [.address(F.safe), .address(to), .uint(UInt256(1))]) }
        let batch = { (to: Address) in
            Self.call("safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)", [.address, .address, .uintArray, .uintArray, .bytes],
                      [.address(F.safe), .address(to), .uints([UInt256(1), UInt256(2)]), .uints([UInt256(5), UInt256(6)]), .bytes(Data())]) }
        for (name, make) in [("tac3", tac3), ("tac2", tac2), ("shares", shares), ("sharesFrom", sharesFrom), ("batch", batch)] {
            let fake = Self.assess(F.unknownToken, make(F.aliceLookalike))
            #expect(Self.rules(fake).contains("R05:red"), "\(name): \(Self.rules(fake))")
            #expect(Self.toSigner(Self.assess(F.unknownToken, make(Self.me.signerProxy))), "\(name)")
        }
        // DAI（主网）：push = transfer，move = transferFrom，pull 从别人那里拉到 Safe。
        let push = Self.call("push(address,uint256)", [.address, .uint(256)], [.address(F.aliceLookalike), .uint(UInt256(1))])
        #expect(Self.rules(Self.assess(Self.dai, push, chain: 1)).contains("R05:red"))
        let move = Self.call("move(address,address,uint256)", [.address, .address, .uint(256)], [.address(F.safe), .address(Self.me.signerProxy), .uint(UInt256(1))])
        #expect(Self.toSigner(Self.assess(Self.dai, move, chain: 1)))
        let pull = Self.call("pull(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(UInt256(1))])
        let p = Self.assess(Self.dai, pull, chain: 1)
        #expect(p.verdict == .green, "\(Self.rules(p))")
    }
}

/// 安全核查 P1-2："接近无限"的授权。阈值按代币单位定：有 decimals 时 ≥ 10^(decimals+9)（10 亿个代币），
/// 没有 decimals 时 ≥ 2^96。对 6 位小数的 USDC，2^128−1 远超所有供应量，等于无限。
struct NearUnlimitedApprovalTests {
    typealias F = Fixture
    static let below128 = UInt256(words: [.max, .max, 0, 0])
    static let oneBillionUSDC = UInt256(1_000_000_000_000_000)  // 10^15 = 10^(6+9)
    static let two96 = UInt256(words: [0, 1 << 32, 0, 0])

    static func approve(_ s: Address, _ n: UInt256) -> Data { F.call("approve(address,uint256)", [.address, .uint(256)], [.address(s), .uint(n)]) }
    static func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }

    @Test func belowTwo128IsUnlimitedForUSDC() {
        #expect(Self.rules(F.assess(to: F.usdc, data: Self.approve(F.stranger, Self.below128))).contains("R03:red"))
        #expect(Self.rules(F.assess(to: F.usdc, data: Self.approve(F.alice, Self.below128))) == ["R03:red"])
        let inc = F.call("increaseAllowance(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(Self.below128)])
        #expect(Self.rules(F.assess(to: F.usdc, data: inc)) == ["R03:red"])
        let p2 = F.call("approve(address,address,uint160,uint48)", [.address, .address, .uint(160), .uint(48)],
                        [.address(F.usdc), .address(F.alice), .uint(Self.below128), .uint(UInt256(1_900_000_000))])
        #expect(Self.rules(F.assess(to: SafeDeployments.permit2, data: p2)) == ["R03:red"])
    }

    @Test func thresholdByDecimals() {
        #expect(Self.rules(F.assess(to: F.usdc, data: Self.approve(F.alice, Self.oneBillionUSDC))) == ["R03:red"])
        #expect(Self.rules(F.assess(to: F.usdc, data: Self.approve(F.alice, Self.oneBillionUSDC.subtracting(UInt256(1))!))) == [])
    }

    @Test func thresholdWithoutDecimals() {
        #expect(Self.rules(F.assess(to: F.unknownToken, data: Self.approve(F.alice, Self.two96))).contains("R03:red"))
        #expect(!Self.rules(F.assess(to: F.unknownToken, data: Self.approve(F.alice, Self.two96.subtracting(UInt256(1))!))).contains("R03:red"))
    }

    /// 对方不在地址簿里的有限授权：至少黄（R06），说明里有金额。
    @Test func limitedApprovalToStrangerIsYellowWithAmount() {
        let a = F.assess(to: F.usdc, data: Self.approve(F.stranger, UInt256(1_500_000)))
        #expect(a.verdict == .yellow && Self.rules(a) == ["R06:yellow"])
        #expect(a.actions[0].explanation.render(.english).contains("1.5"))
    }
}

/// 安全核查 P2-1 / P2-2：R05 按"前缀相同位数 + 后缀相同位数 ≥ 6"判，怎么分都算；比对对象不按链过滤，
/// 豁免只认当前链的地址簿条目、当前链的"我的 Safe"和本机签名人地址，Safe 的 owners 只当比对对象。
struct LookalikeMatchingTests {
    typealias F = Fixture
    static func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }
    static func hex(_ s: String) -> Address { Address(hex: "0x" + s)! }
    static func nines(_ n: Int) -> String { String(repeating: "9", count: n) }

    @Test func anySplitOfSixMatches() {
        // alice = 0x1111…1111
        for (name, a) in [("2+8", Self.hex("11" + Self.nines(30) + "11111111")), ("8+2", Self.hex("11111111" + Self.nines(30) + "11")),
                          ("6+0", Self.hex("111111" + Self.nines(34))), ("0+6", Self.hex(Self.nines(34) + "111111")),
                          ("4+2", Self.hex("1111" + Self.nines(34) + "11"))] {
            #expect(Self.rules(F.assess(to: a, value: UInt256(1))) == ["R05:red"], "\(name)")
        }
        for (name, a) in [("5+0", Self.hex("11111" + Self.nines(35))), ("2+3", Self.hex("11" + Self.nines(35) + "111"))] {
            #expect(Self.rules(F.assess(to: a, value: UInt256(1))) == ["R06:yellow"], "\(name)")
        }
    }

    @Test func comparisonIgnoresChain() {
        let ctx = F.context(book: [AddressBookEntry(address: F.alice, label: "Alice", chainID: 1)])
        #expect(Self.rules(F.assess(to: F.aliceLookalike, value: UInt256(1), context: ctx)) == ["R05:red"])
    }

    @Test func ownersAreNotExempt() {
        let other = MySafe(chainID: F.chain, address: Self.hex("5afe" + String(repeating: "0", count: 32) + "b0b0"), name: "B",
                           owners: [F.aliceLookalike], threshold: 1)
        let ctx = F.context(safes: [MySafe(chainID: F.chain, address: F.safe, name: "金库"), other])
        #expect(Self.rules(F.assess(to: F.aliceLookalike, value: UInt256(1), context: ctx)) == ["R05:red"])
    }

    @Test func bookEntryOnOtherChainIsNotExempt() {
        let ctx = F.context(book: [AddressBookEntry(address: F.alice, label: "Alice"),
                                   AddressBookEntry(address: F.aliceLookalike, label: "x", chainID: 8453)])
        #expect(Self.rules(F.assess(to: F.aliceLookalike, value: UInt256(1), context: ctx)) == ["R05:red"])
        // 当前链的条目照旧豁免。
        let same = F.context(book: [AddressBookEntry(address: F.alice, label: "Alice"),
                                    AddressBookEntry(address: F.aliceLookalike, label: "x", chainID: F.chain)])
        #expect(Self.rules(F.assess(to: F.aliceLookalike, value: UInt256(1), context: same)) == [])
    }
}

/// 安全核查 P2-3：对别的 Safe（嵌套 Safe）做 owner 管理或执行交易，以及用 Safe 的管理 / 执行类函数调用任何合约，按 R02 判红。
struct NestedSafeTests {
    typealias F = Fixture
    static let safeB = Address(hex: "0x5afe00000000000000000000000000000000b0b0")!
    static let attacker = Address(hex: "0xa77ac0000000000000000000000000000000beef")!
    static func ctx() -> RiskContext {
        F.context(safes: [MySafe(chainID: F.chain, address: F.safe, name: "A"), MySafe(chainID: F.chain, address: Self.safeB, name: "B")])
    }
    static func rules(_ a: RiskAssessment) -> [String] { a.findings.map { "\($0.rule.rawValue):\($0.level)" } }
    static let add = F.call("addOwnerWithThreshold(address,uint256)", [.address, .uint(256)], [.address(attacker), .uint(UInt256(1))])
    static let approveHash = Data(Keccak.hash256(Data("approveHash(bytes32)".utf8)).prefix(4)) + Data(count: 32)
    static let exec = F.call("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                             [.address, .uint(256), .bytes, .uint(8), .uint(256), .uint(256), .uint(256), .address, .address, .bytes],
                             [.address(attacker), .uint(.zero), .bytes(Data()), .uint(UInt256(1)), .uint(.zero), .uint(.zero), .uint(.zero),
                              .address(.zero), .address(.zero), .bytes(Data(count: 65))])

    @Test func callsIntoAnotherMySafeAreRed() {
        for (name, data) in [("addOwner", Self.add), ("approveHash", Self.approveHash), ("execTransaction", Self.exec)] {
            let a = F.assess(to: Self.safeB, data: data, context: Self.ctx())
            #expect(Self.rules(a).contains("R02:red"), "\(name): \(Self.rules(a))")
        }
    }

    @Test func safeFunctionsOnAnyContractAreRed() {
        for (name, data) in [("addOwner", Self.add), ("approveHash", Self.approveHash), ("execTransaction", Self.exec)] {
            let a = F.assess(to: F.stranger, data: data, context: Self.ctx())
            #expect(Self.rules(a).contains("R02:red"), "\(name): \(Self.rules(a))")
        }
    }

    /// 对 Safe 自己用"任何合约都适用"的函数（例如 approve）也算 R02。
    @Test func tokenFunctionOnThisSafeIsRed() {
        let approve = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.stranger), .uint(UInt256(1))])
        #expect(Self.rules(F.assess(to: F.safe, data: approve, context: Self.ctx())).contains("R02:red"))
    }

    /// 单纯往自己别的 Safe 转 ETH 照旧是绿的。
    @Test func plainTransferToAnotherMySafeIsGreen() {
        #expect(F.assess(to: Self.safeB, value: UInt256(1), context: Self.ctx()).verdict == .green)
    }
}

/// 安全核查 P2-4：确认字符按（规则、位置、对象）去重，不按字符串值去重。两条红色发现项要求的字符撞了，
/// 也要各输一次不同的字符，不能输一次同时放过两条。
struct ConfirmationDedupTests {
    typealias F = Fixture

    /// DELEGATECALL 目标（SafeMigration 1.4.1，后 4 位 DAC6）和无限授权对象的后 4 位刻意相同。
    @Test func collidingValuesStaySeparate() {
        let friend = Address(hex: "0xe011000000000000000000000000000000e0dac6")!
        let unlimited = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(friend), .uint(F.max256)])
        let book = F.context(book: [AddressBookEntry(address: friend, label: "Friend")])
        let a = F.assess(to: F.ms141, data: F.multiSend([(0, F.usdc, .zero, unlimited), (1, DelegateCallPolicyTests.safeMigration141, .zero, Data())]),
                         op: .delegateCall, context: book)
        let p = ConfirmationPhrase(a)
        #expect(a.verdict == .red)
        #expect(p.tokens.count == 2, "\(p.tokens.map(\.expected))")
        #expect(Set(p.tokens.map(\.expected)).count == p.tokens.count)
        #expect(!p.matches("DAC6"))
        #expect(p.matches(p.tokens.map(\.expected).joined(separator: " ")))
    }

    /// 同一个地址在两条调用里被标红（ERC-20 无限授权 + NFT 全部授权）：两条都要输，字符不同。
    @Test func sameAddressDifferentRules() {
        let unlimited = F.call("approve(address,uint256)", [.address, .uint(256)], [.address(F.alice), .uint(F.max256)])
        let forAll = F.call("setApprovalForAll(address,bool)", [.address, .bool], [.address(F.alice), .bool(true)])
        let a = F.assess(to: F.ms141, data: F.multiSend([(0, F.usdc, .zero, unlimited), (0, F.nft, .zero, forAll)]), op: .delegateCall)
        let p = ConfirmationPhrase(a)
        #expect(p.tokens.count == 2 && Set(p.tokens.map(\.expected)).count == 2, "\(p.tokens.map(\.expected))")
    }
}

/// R01 改判（用户决定，2026-10-28）：正常使用完全不会出现的 DELEGATECALL 一律硬拒，不提供输入确认字符的入口。
/// 只有 Safe 官方的升级 / 部署库（SafeMigration、SafeToL2Migration、CreateCall）保留 R01 红加确认字符。
struct DelegateCallPolicyTests {
    typealias F = Fixture
    static let safeMigration141 = Address(hex: "0x526643F69b81B008F46d95CD5ced5eC0edFFDaC6")!
    static let createCall141 = Address(hex: "0x9b35Af71d77eaf8d7e40252370304687390A1A52")!
    static let signMessageLib141 = Address(hex: "0xd53cd0aB83D845Ac265BE939c57F53AD838012c9")!
    static let safeToL2Setup141 = Address(hex: "0xBD89A1CE4DDe368FFAB0eC35506eEcE0b1fFdc54")!
    static let simulateTxAccessor141 = Address(hex: "0x3d4BA2E0884aa488718476ca2FB8Efc291A46199")!
    static func rejectedForDelegateCall(_ a: RiskAssessment) -> Bool {
        a.verdict == .rejected && a.rejections.contains { if case .delegateCallNotAllowed = $0.reason { true } else { false } }
    }

    @Test func unknownTargetIsRejected() {
        #expect(Self.rejectedForDelegateCall(F.assess(to: F.stranger, op: .delegateCall)))
        // MultiSend 里、嵌套 MultiSend 里也一样。
        #expect(Self.rejectedForDelegateCall(F.assess(to: F.ms141, data: F.multiSend([(1, F.stranger, .zero, Data())]), op: .delegateCall)))
        let inner = F.multiSend([(1, F.stranger, .zero, Data())])
        #expect(Self.rejectedForDelegateCall(F.assess(to: F.ms141, data: F.multiSend([(1, F.ms141, .zero, inner)]), op: .delegateCall)))
    }

    /// 签名器能识别的 Safe 官方库里，消息签名、仅供 setup、仅供模拟的几个在 SafeTx 里没有正当用途，也硬拒。
    @Test func unusedOfficialLibrariesAreRejected() {
        for lib in [Self.signMessageLib141, Self.safeToL2Setup141, Self.simulateTxAccessor141] {
            #expect(Self.rejectedForDelegateCall(F.assess(to: lib, data: Data([1, 2, 3, 4]), op: .delegateCall)), "\(lib)")
        }
    }

    /// 升级 Safe 版本、从 Safe 部署合约：少见但正当，保留 R01 红，可以输入确认字符越过。
    @Test func upgradeAndDeployLibrariesStayRed() {
        for lib in [Self.safeMigration141, Self.createCall141] {
            let a = F.assess(to: lib, data: Data([1, 2, 3, 4]), op: .delegateCall)
            #expect(a.verdict == .red && a.findings.first?.rule == .R01 && a.rejections.isEmpty, "\(lib)")
        }
    }

    /// 允许名单里的每个地址在每条支持的链上都是标签库里的 Safe 官方库。
    @Test func allowListMatchesLabelLibrary() {
        for a in SafeDeployments.delegateCallLibraries {
            for chain in SafeDeployments.supportedChains {
                let e = LabelLibrary.builtIn.lookup(chainID: chain, address: a)
                #expect(e?.kind == .safeLibrary && ["SafeMigration", "SafeToL2Migration", "CreateCall"].contains { e!.name.contains($0) }, "\(a) on \(chain)")
            }
        }
    }

    /// 被拒的交易没有越过的入口：给出确认字符也签不了。
    @Test func noConfirmationEntry() {
        let a = F.assess(to: F.stranger, op: .delegateCall)
        #expect(throws: SignableTransaction.Refusal.self) { try SignableTransaction(a, confirmation: "R01") }
    }
}
