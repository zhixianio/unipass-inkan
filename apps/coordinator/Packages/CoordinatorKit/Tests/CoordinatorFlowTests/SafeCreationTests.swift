import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

/// 创建 Safe 的编码、添加已有 Safe 的核对、本地 Safe 列表。
@Suite struct SafeCreationTests {
    static let signerX = Data(hex: "0x9412d01c528c544a603df018722a38f1a982388e3c688fcc37bfafae34a272dd")!
    static let signerY = Data(hex: "0x19dc995467d9a5cf62f18a144cd44d52bf17553155065e2ca73977d0ce24469d")!
    static let verifiers = Data(hex: "0x0100445a0683e494ea0c5af3e83c5159fbe47cf9e765")!
    static let proxy = Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!
    static let eoa = Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!

    /// contracts/script/DeployTestSafe.s.sol 在 Sepolia 上发出的那笔（0xa9e27b58…c7cb）的调用数据。
    static let sepoliaDeployment = Data(hex: "0x" + [
        "8d80ff0a000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000",
        "00000332001d31f259ee307358a26dfb23eb365939e8641195000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "000000000000000000000000000000000000000000000000640d2f04899412d01c528c544a603df018722a38f1a982388e3c688fcc37bfafae34a272dd19dc99",
        "5467d9a5cf62f18a144cd44d52bf17553155065e2ca73977d0ce24469d000000000000000000000100445a0683e494ea0c5af3e83c5159fbe47cf9e765004e1d",
        "cf7ad4e460cfd30791ccc4f9c8a4f820ec6700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000002241688f0b900000000000000000000000029fcb43b46531bca003ddc8fcb67ffe91900c76200000000000000000000",
        "00000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "00000000000000000000000000000000000000000184b63e800d0000000000000000000000000000000000000000000000000000000000000100000000000000",
        "00000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000160000000000000000000000000fd0732dc9e303f09fcef3a7388ad10a83459ec99000000000000",
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000",
        "000000000000c8f9e2ba66e640b05d6d8da4f00f567679bc9a06000000000000000000000000938313a557b6129d2d8cbda84ad962b1869ab39a000000000000",
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "00000000",
    ].joined())!

    @Test func reproducesTheSepoliaDeployment() {
        let r = SafeCreation.registration(chainID: 11_155_111, owners: [Self.proxy, Self.eoa], threshold: 2, saltNonce: .zero, name: nil)
        #expect(r.safe == Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!)
        let signer = SafeCreation.NewSigner(x: Self.signerX, y: Self.signerY, verifiers: Self.verifiers, proxy: Self.proxy)
        #expect(SafeCreation.deploymentCalldata(deploying: [signer], safe: r) == Self.sepoliaDeployment)
    }

    @Test func defaultThresholdIsMajority() {
        #expect([1, 2, 3, 4, 5].map(SafeCreation.defaultThreshold) == [1, 2, 2, 3, 3])
    }

    @Test func randomSaltNoncesDiffer() {
        #expect(SafeCreation.randomSaltNonce() != SafeCreation.randomSaltNonce())
    }

    // MARK: 添加已有 Safe

    static var testSafe: SafeRegistration { KnownSafes.sepoliaTestSafe }

    static var unchanged: ExistingSafe.OnChain {
        ExistingSafe.OnChain(owners: testSafe.owners, threshold: 2, modules: [], guardAddress: .zero,
                             fallbackHandler: testSafe.fallbackHandler, singleton: testSafe.singleton)
    }

    @Test func decodesSetupDataBack() throws {
        let r = Self.testSafe
        let back = try ExistingSafe.registration(chainID: r.chainID, safe: r.safe, factory: r.proxyFactory, singleton: r.singleton,
                                                 setupData: SafeAddress.setupCalldata(r), saltNonce: r.saltNonce, name: r.name)
        #expect(back == r)
        var tampered = SafeAddress.setupCalldata(r)
        tampered.append(0)
        #expect(throws: ExistingSafe.Problem.setupNotDecodable) {
            try ExistingSafe.registration(chainID: r.chainID, safe: r.safe, factory: r.proxyFactory, singleton: r.singleton,
                                          setupData: tampered, saltNonce: r.saltNonce, name: nil)
        }
    }

    /// 其他 owner 不经过配对的签名器就能凑够门限（比如 2-of-3 的 Inkan + Ledger + Trezor）：可以添加，但要用户先确认；
    /// 不确认就加不进去。需要配对的签名器才够门限的，不出现这个确认。
    @Test func safesThatDontNeedAPairedSignerNeedAcknowledgement() {
        let mine = Self.proxy
        let mine2 = Address(hex: "0x00000000000000000000000000000000000000B2")!
        let a = Address(hex: "0x00000000000000000000000000000000000000aa")!
        let b = Address(hex: "0x00000000000000000000000000000000000000bb")!
        func check(_ owners: [Address], _ threshold: UInt64, paired: Set<Address> = [Self.proxy]) -> (ExistingSafe.Problem?, ExistingSafe.Review) {
            let r = SafeCreation.registration(chainID: 11_155_111, owners: owners, threshold: threshold, saltNonce: UInt256(42), name: nil)
            let onChain = ExistingSafe.OnChain(owners: r.owners, threshold: threshold, modules: [], guardAddress: .zero,
                                               fallbackHandler: r.fallbackHandler, singleton: r.singleton)
            return (ExistingSafe.problem(r, onChain: onChain, service: onChain, signers: paired), ExistingSafe.Review(r, paired: paired))
        }
        for (owners, threshold) in [([mine, a], UInt64(1)), ([mine, a, b], 2)] {
            let (problem, review) = check(owners, threshold)
            #expect(problem == nil)
            #expect(review.needsAcknowledgement)
            #expect(review.unpairedSigners == owners.count - 1)
            #expect(!review.canAdd(acknowledged: false))
            #expect(review.canAdd(acknowledged: true))
        }
        for (owners, threshold, paired) in [([mine], UInt64(1), Set([mine])), ([mine, a], 2, [mine]), ([mine, a, b], 3, [mine]),
                                            ([mine, mine2, a], 2, [mine, mine2])] {
            let (problem, review) = check(owners, threshold, paired: paired)
            #expect(problem == nil)
            #expect(!review.needsAcknowledgement)
            #expect(review.canAdd(acknowledged: false))
        }
    }

    /// 节点和交易服务各说各的：不收。只信一个 RPC 时，撒谎的节点可以把已经加了 module 的 Safe 说成没改过。
    @Test func refusesWhenNodeAndServiceDisagree() {
        let r = Self.testSafe
        let attacker = Address(hex: "0x00000000000000000000000000000000000000aa")!
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: Self.unchanged, signers: [Self.proxy]) == nil)
        var withModule = Self.unchanged
        withModule.modules = [attacker]
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: withModule, signers: [Self.proxy]) == .sourcesDisagree)
        var otherHandler = Self.unchanged
        otherHandler.fallbackHandler = attacker
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: otherHandler, signers: [Self.proxy]) == .sourcesDisagree)
        var reordered = Self.unchanged
        reordered.owners.reverse()
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: reordered, signers: [Self.proxy]) == nil)
        #expect(ExistingSafe.disagreements(Self.unchanged, withModule) == [.modules])
    }

    /// 加进来以后复查：module、guard、fallback handler、singleton 和创建时比，变了的都报出来。
    @Test func reportsConfigurationChangesAfterAdding() {
        let r = Self.testSafe
        let attacker = Address(hex: "0x00000000000000000000000000000000000000aa")!
        #expect(ExistingSafe.configurationChanges(r, now: Self.unchanged).isEmpty)
        var c = Self.unchanged
        c.modules = [attacker]
        c.guardAddress = attacker
        #expect(ExistingSafe.configurationChanges(r, now: c) == [.modules, .guardAddress])
        c = Self.unchanged
        c.fallbackHandler = attacker
        c.singleton = attacker
        #expect(ExistingSafe.configurationChanges(r, now: c) == [.fallbackHandler, .singleton])
        // 换签名人、改门限是正常操作，不在这里报。
        c = Self.unchanged
        c.owners = [Self.proxy]
        c.threshold = 1
        #expect(ExistingSafe.configurationChanges(r, now: c).isEmpty)
    }

    @Test func acceptsOnlyUnchangedSafesWithThisSigner() {
        let r = Self.testSafe
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: Self.unchanged, signers: [Self.proxy]) == nil)
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: Self.unchanged, signers: [Address(hex: "0x00000000000000000000000000000000000000aa")!]) == .signerNotOwner)
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: Self.unchanged, signers: []) == .signerNotOwner)
        // 配对了几台：其中一台在 owner 里就行
        #expect(ExistingSafe.problem(r, onChain: Self.unchanged, service: Self.unchanged, signers: [Address(hex: "0x00000000000000000000000000000000000000aa")!, Self.proxy]) == nil)

        var c = Self.unchanged
        c.owners = [Self.proxy]
        #expect(ExistingSafe.problem(r, onChain: c, service: c, signers: [Self.proxy]) == .ownersChanged)
        c = Self.unchanged
        c.threshold = 1
        #expect(ExistingSafe.problem(r, onChain: c, service: c, signers: [Self.proxy]) == .thresholdChanged)
        c = Self.unchanged
        c.modules = [Self.eoa]
        #expect(ExistingSafe.problem(r, onChain: c, service: c, signers: [Self.proxy]) == .hasModules)
        c = Self.unchanged
        c.guardAddress = Self.eoa
        #expect(ExistingSafe.problem(r, onChain: c, service: c, signers: [Self.proxy]) == .hasGuard)
        c = Self.unchanged
        c.fallbackHandler = Self.eoa
        #expect(ExistingSafe.problem(r, onChain: c, service: c, signers: [Self.proxy]) == .fallbackHandlerChanged)
        c = Self.unchanged
        c.singleton = Self.eoa
        #expect(ExistingSafe.problem(r, onChain: c, service: c, signers: [Self.proxy]) == .singletonChanged)

        var wrongAddress = r
        wrongAddress.safe = Self.eoa
        #expect(ExistingSafe.problem(wrongAddress, onChain: Self.unchanged, service: Self.unchanged, signers: [Self.proxy]) == .addressMismatch)
        var extra = r
        extra.to = Self.eoa
        extra.data = Data([1])
        extra.safe = SafeAddress.compute(extra)!
        #expect(ExistingSafe.problem(extra, onChain: Self.unchanged, service: Self.unchanged, signers: [Self.proxy]) == .extraSetupCall)
        var unknown = r
        unknown.singleton = Self.eoa
        #expect(ExistingSafe.problem(unknown, onChain: Self.unchanged, service: Self.unchanged, signers: [Self.proxy]) == .unsupportedFactoryOrVersion)
    }

    /// 创建参数和签名器登记时用同一份核对（core 的 `SafeAddress.verify`）：setup 带付款、创建时装了非官方的 fallback handler
    ///（它会替 Safe 回答 EIP-1271 签名校验），桌面端在添加时就拒绝，不等签名器登记时才发现。
    @Test func refusesWhatTheSignerWouldRefuse() {
        let attacker = Address(hex: "0x00000000000000000000000000000000000BAD00")!
        func created(_ change: (inout SafeRegistration) -> Void) -> SafeRegistration {
            var r = Self.testSafe
            change(&r)
            r.safe = SafeAddress.compute(r)!
            return r
        }
        func problem(_ r: SafeRegistration) -> ExistingSafe.Problem? {
            var onChain = Self.unchanged
            onChain.fallbackHandler = r.fallbackHandler
            return ExistingSafe.problem(r, onChain: onChain, service: onChain, signers: [Self.proxy])
        }
        for r in [created { $0.payment = UInt256(1); $0.paymentReceiver = attacker },
                  created { $0.paymentToken = attacker },
                  created { $0.paymentReceiver = attacker }] {
            #expect(problem(r) == .setupPayment)
        }
        #expect(problem(created { $0.fallbackHandler = attacker }) == .unofficialFallbackHandler)
        // 官方的，但版本不对（1.3.0 的 handler 配 1.4.1 的 singleton）。
        #expect(problem(created { $0.fallbackHandler = Address(hex: "0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4")! }) == .unofficialFallbackHandler)
        // 只有 data、to 为零也算额外调用。
        #expect(problem(created { $0.data = Data([1]) }) == .extraSetupCall)
        // 零地址 handler 照常可以添加。
        #expect(problem(created { $0.fallbackHandler = .zero }) == nil)
        var otherChain = Self.testSafe
        otherChain.chainID = 10
        #expect(problem(otherChain) == .unsupportedNetwork)
    }

    // MARK: 签名人地址不能收款

    @Test func signerContractsCantReceive() {
        let owners: Set<Address> = [Self.proxy, Self.eoa]
        // 已配对签名器的地址：不管链上有没有部署
        #expect(SignerAddresses.isSignerContract(Self.proxy, pairedSigners: [Self.proxy], safeOwners: [], hasCode: false))
        // 其他签名人：链上有代码（合约）才拦，EOA 签名人照常能收款
        #expect(SignerAddresses.isSignerContract(Self.proxy, pairedSigners: [], safeOwners: owners, hasCode: true))
        #expect(!SignerAddresses.isSignerContract(Self.eoa, pairedSigners: [Self.proxy], safeOwners: owners, hasCode: false))
        // 不是签名人的合约（比如代币合约）不归这条管
        #expect(!SignerAddresses.isSignerContract(Address(hex: "0x00000000000000000000000000000000000000aa")!, pairedSigners: [Self.proxy], safeOwners: owners, hasCode: true))
    }

    // MARK: 本地 Safe 列表

    @Test func storeRoundTripsAndSelects() throws {
        var store = SafeStore()
        #expect(store.current == nil)
        let a = Self.testSafe
        let b = SafeCreation.registration(chainID: 8453, owners: [Self.proxy], threshold: 1, saltNonce: UInt256(7), name: "Base")
        store.add(a)
        store.add(b)
        #expect(store.current == b)
        store.select(SafeStore.SafeID(a))
        #expect(store.current == a)
        store.add(a)
        #expect(store.safes.count == 2)

        let back = try SafeStore(decoding: try store.encoded())
        #expect(back == store)

        store.remove(SafeStore.SafeID(a))
        #expect(store.current == b)
        #expect(store.contains(chainID: 8453, address: b.safe))
        #expect(!store.contains(chainID: 11_155_111, address: b.safe))
    }
}
