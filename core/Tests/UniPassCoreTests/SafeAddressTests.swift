import Foundation
import Testing
@testable import UniPassCore

/// 真实向量：contracts/ 在 Sepolia 上部署的测试 Safe（contracts/README.md、script/DeployTestSafe.s.sol）：
/// SafeL2 1.4.1，owner = [Signer proxy, 测试 EOA]，门限 2，1.4.1 的 CompatibilityFallbackHandler，saltNonce 0。
struct SafeAddressTests {
    static let sepoliaTestSafe = SafeRegistration(
        chainID: 11_155_111, safe: Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!,
        proxyFactory: Address(hex: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67")!,
        singleton: Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!, saltNonce: .zero,
        owners: [Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!, Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!],
        threshold: 2, fallbackHandler: Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!)

    @Test func sepoliaTestSafeVerifies() throws {
        let ic = try SafeAddress.verify(Self.sepoliaTestSafe)
        #expect(ic.version == "1.4.1" && ic.isL2)
    }

    @Test func anyChangeBreaksVerification() {
        var r = Self.sepoliaTestSafe
        r.threshold = 1
        #expect(throws: SafeAddress.VerificationError.self) { try SafeAddress.verify(r) }
        r = Self.sepoliaTestSafe
        r.owners.reverse()
        #expect(throws: SafeAddress.VerificationError.self) { try SafeAddress.verify(r) }
        r = Self.sepoliaTestSafe
        r.saltNonce = UInt256(1)
        #expect(throws: SafeAddress.VerificationError.self) { try SafeAddress.verify(r) }
        r = Self.sepoliaTestSafe
        r.singleton = Address(hex: "0x41675C099F32341bf84BFc5382aF534df5C7461a")!  // Safe 1.4.1（非 L2）：组合合法但地址不同
        #expect(throws: SafeAddress.VerificationError.self) { try SafeAddress.verify(r) }
        r = Self.sepoliaTestSafe
        r.singleton = Address(hex: "0x0000000000000000000000000000000000001234")!
        #expect(throws: SafeAddress.VerificationError.unknownFactoryOrSingleton) { try SafeAddress.verify(r) }
        r = Self.sepoliaTestSafe
        r.chainID = 10
        #expect(throws: SafeAddress.VerificationError.unsupportedChain(10)) { try SafeAddress.verify(r) }
    }

    static func word(_ n: Int) -> Data { UInt256(UInt64(n)).bigEndianBytes }

    /// `createProxyWithNonce(singleton, initializer, saltNonce)` 的标准编码。
    static func createProxyWithNonce(_ r: SafeRegistration, initializer: Data? = nil) -> Data {
        let i = initializer ?? SafeAddress.setupCalldata(r)
        return SafeAddress.createProxyWithNonceSelector + r.singleton.abiEncoded + word(96) + r.saltNonce.bigEndianBytes
            + word(i.count) + i + Data(count: (32 - i.count % 32) % 32)
    }

    /// 解码创建交易：解出的参数和测试 Safe 一致，CREATE2 地址就是链上那个，并且能过 `verify`。
    @Test func decodesTheCreationCall() throws {
        let t = Self.sepoliaTestSafe
        #expect(SafeAddress.createProxyWithNonceSelector.hexString == "0x1688f0b9")
        let back = try #require(SafeAddress.registration(chainID: t.chainID, safe: t.safe, factory: t.proxyFactory, singleton: t.singleton,
                                                         saltNonce: t.saltNonce, setupCalldata: SafeAddress.setupCalldata(t)))
        #expect(back == t)
        let created = try #require(SafeAddress.registration(chainID: t.chainID, factory: t.proxyFactory,
                                                            createProxyWithNonce: Self.createProxyWithNonce(t)))
        #expect(created == t)
        _ = try SafeAddress.verify(created)
        // 不是官方的 factory：地址算不出来，verify 拒绝。
        let other = Address(hex: "0x0000000000000000000000000000000000001234")!
        let unknown = try #require(SafeAddress.registration(chainID: t.chainID, factory: other, createProxyWithNonce: Self.createProxyWithNonce(t)))
        #expect(unknown.safe == .zero)
        #expect(throws: SafeAddress.VerificationError.unknownFactoryOrSingleton) { try SafeAddress.verify(unknown) }
    }

    /// 解出的参数照常要过 `verify`：setup 带额外调用的能解出来，但核对不过。
    @Test func decodedSetupIsVerifiedLikeARegistration() throws {
        var r = Self.sepoliaTestSafe
        r.to = Address(hex: "0x00000000000000000000000000000000000BAD00")!
        r.data = Data([0xde, 0xad])
        let created = try #require(SafeAddress.registration(chainID: r.chainID, factory: r.proxyFactory, createProxyWithNonce: Self.createProxyWithNonce(r)))
        #expect(created.to == r.to && created.data == r.data && created.safe == SafeAddress.compute(r))
        #expect(throws: SafeAddress.VerificationError.setupCall(to: r.to)) { try SafeAddress.verify(created) }
    }

    /// 不是 `setup`、编码不规范（偏移、地址高位、补齐、多余或缺少字节）的一律解不出来。
    @Test func onlyCanonicalSetupDecodes() {
        let t = Self.sepoliaTestSafe
        let good = SafeAddress.setupCalldata(t)
        func decode(_ d: Data) -> SafeRegistration? {
            SafeAddress.registration(chainID: t.chainID, safe: t.safe, factory: t.proxyFactory, singleton: t.singleton,
                                     saltNonce: t.saltNonce, setupCalldata: d)
        }
        // owners 的偏移改成 0x120，后面整体挪一个字（Solidity 能解，但不规范）。
        var shifted = Data(good.prefix(4)) + Self.word(0x120) + good[36..<100] + Self.word(0x180) + good[132..<260]
        shifted += Data(count: 32) + good[260...]
        var highBits = good
        highBits[4 + 32 * 2] = 1 // to 的高位
        var badPadding = SafeAddress.setupCalldata({ var r = t; r.data = Data([1]); return r }())
        badPadding[badPadding.count - 1] = 1
        let enableModule = Data(Keccak.hash256(Data("enableModule(address)".utf8)).prefix(4)) + Data(count: 32)
        for d in [Data(), enableModule, Data(repeating: 2, count: 4 + 32 * 12), good.prefix(good.count - 32), good + Data(count: 32),
                  shifted, highBits, badPadding] {
            #expect(decode(d) == nil)
        }
        // createProxyWithNonce 本身不规范：bytes 偏移不是 0x60、末尾多字节、截断、换了函数。
        let call = Self.createProxyWithNonce(t)
        var offset128 = SafeAddress.createProxyWithNonceSelector + t.singleton.abiEncoded + Self.word(128) + t.saltNonce.bigEndianBytes
        offset128 += Data(count: 32) + Self.word(good.count) + good + Data(count: (32 - good.count % 32) % 32)
        for d in [offset128, call + Data(count: 32), call.prefix(call.count - 32), Data([0, 0, 0, 0]) + call.dropFirst(4)] {
            #expect(SafeAddress.registration(chainID: t.chainID, factory: t.proxyFactory, createProxyWithNonce: Data(d)) == nil)
        }
    }

    @Test func tableShape() {
        #expect(SafeAddress.initCodes.count == 32)
        #expect(Set(SafeAddress.initCodes.map { "\($0.factory)\($0.singleton)" }).count == 32)
    }
}

/// 登记时这台 Signer 必须在创建时的 owner 里；S4：签名请求和登记信息一起扫。
struct RegistrationTests {
    static let safe = SafeAddressTests.sepoliaTestSafe
    static let me = safe.owners[0]

    static func signRequest(chainID: UInt64 = 11_155_111, safe: Address = Self.safe.safe) -> EthSignRequest {
        let req = SafeTxRequest(chainID: chainID, safe: safe, tx: SafeTx(to: me, value: UInt256(1), nonce: .zero))
        return EthSignRequest(requestID: Data(repeating: 7, count: 16), signData: Data(req.canonicalJSON.utf8), dataType: .typedData,
                              chainID: chainID, derivationPath: CryptoKeypath(components: [], sourceFingerprint: 1))
    }

    @Test func signerMustBeAnOwner() throws {
        let v = try SafeAddress.verify(Self.safe, signer: Self.me)
        #expect(v.signer == Self.me && v.initCode.version == "1.4.1" && v.registration == Self.safe)
        let stranger = Address(hex: "0x00000000000000000000000000000000000000aa")!
        #expect(throws: SafeAddress.VerificationError.signerNotAnOwner(stranger)) { try SafeAddress.verify(Self.safe, signer: stranger) }
        // 先核对 CREATE2：参数被改过时报地址错误，不是"不是 owner"。
        var r = Self.safe
        r.owners[1] = stranger
        #expect(throws: SafeAddress.VerificationError.self) { try SafeAddress.verify(r, signer: Self.me) }
        #expect((try? SafeAddress.verify(r, signer: Self.me)) == nil)
        do { _ = try SafeAddress.verify(r, signer: stranger) } catch let e as SafeAddress.VerificationError {
            guard case .addressMismatch = e else { Issue.record("\(e)"); return }
        }
    }

    @Test func combinedRequestRoundTrip() throws {
        let c = SignRequestWithSafe(request: Self.signRequest(), registration: Self.safe)
        let parsed = try SignRequestWithSafe(ur: UR(parsing: c.ur.qrString))
        #expect(parsed == c)
        #expect(parsed.requestTargetsRegisteredSafe == true)
        // 结构：{1: #6.401(eth-sign-request), 2: #6.41402(unipass-safe)}，内层就是两种类型各自的编码。
        let m = try #require(c.cbor.mapValue)
        #expect(m[1] == .tagged(401, c.request.cbor) && m[2] == .tagged(41402, Self.safe.cbor))
        #expect(c.cbor.encoded().prefix(4) == Data([0xA2, 0x01, 0xD9, 0x01]))
        #expect(c.ur.type == "unipass-sign-request")
    }

    @Test func combinedRequestIsStrict() throws {
        let c = SignRequestWithSafe(request: Self.signRequest(), registration: Self.safe)
        let req = c.request.cbor, reg = Self.safe.cbor
        let bad: [CBOR] = [
            .map(try CBORMap([(.unsigned(1), .tagged(401, req))])),  // 缺登记
            .map(try CBORMap([(.unsigned(2), .tagged(41402, reg))])),  // 缺请求
            .map(try CBORMap([(.unsigned(1), req), (.unsigned(2), .tagged(41402, reg))])),  // 请求没带 tag
            .map(try CBORMap([(.unsigned(1), .tagged(401, req)), (.unsigned(2), .tagged(41400, reg))])),  // tag 不对
            .map(try CBORMap([(.unsigned(1), .tagged(401, req)), (.unsigned(2), .tagged(41402, reg)), (.unsigned(3), .unsigned(0))])),  // 多余的键
        ]
        for b in bad { #expect(throws: URTypeError.self) { try SignRequestWithSafe(cbor: b) } }
        #expect(throws: URTypeError.self) { try SignRequestWithSafe(ur: Self.safe.ur) }
    }

    @Test func requestMustTargetTheRegisteredSafe() {
        let other = Address(hex: "0x00000000000000000000000000000000000000ab")!
        #expect(SignRequestWithSafe(request: Self.signRequest(safe: other), registration: Self.safe).requestTargetsRegisteredSafe == false)
        #expect(SignRequestWithSafe(request: Self.signRequest(chainID: 1), registration: Self.safe).requestTargetsRegisteredSafe == false)
        var junk = Self.signRequest()
        junk.signData = Data("{}".utf8)
        #expect(SignRequestWithSafe(request: junk, registration: Self.safe).requestTargetsRegisteredSafe == nil)
    }
}

/// 安全核查 P0-1：CREATE2 只证明创建参数，证明不了 setup 执行后的状态。setup 里的 to/data（DELEGATECALL）、
/// payment 和非官方 fallback handler 都能在创建时改掉 Safe，所以登记时一律拒绝。
struct SetupHardeningTests {
    static let me = RegistrationTests.me
    static let attacker = Address(hex: "0x1111111111111111111111111111111111111111")!

    /// 在测试 Safe 的基础上改参数，并按新参数重算地址（CREATE2 本身一定对得上）。
    static func registration(_ change: (inout SafeRegistration) -> Void) -> SafeRegistration {
        var r = SafeAddressTests.sepoliaTestSafe
        change(&r)
        r.safe = SafeAddress.compute(r)!
        return r
    }

    @Test func setupDelegatecallIsRejected() throws {
        let r = Self.registration { $0.to = Self.attacker; $0.data = Data([0xde, 0xad, 0xbe, 0xef]) }
        let decoded = try SafeRegistration(ur: r.ur)
        #expect(throws: SafeAddress.VerificationError.setupCall(to: Self.attacker)) { try SafeAddress.verify(decoded, signer: Self.me) }
        // 只有 data、to 为零也不行（Safe 只在 to 非零时调用，但这种登记没有正当用途）。
        let dataOnly = Self.registration { $0.data = Data([0x01]) }
        #expect(throws: SafeAddress.VerificationError.setupCall(to: .zero)) { try SafeAddress.verify(dataOnly, signer: Self.me) }
    }

    @Test func paymentIsRejected() {
        for r in [Self.registration { $0.payment = UInt256(1); $0.paymentReceiver = Self.attacker },
                  Self.registration { $0.paymentToken = Self.attacker },
                  Self.registration { $0.paymentReceiver = Self.attacker }] {
            #expect(throws: SafeAddress.VerificationError.setupPayment) { try SafeAddress.verify(r, signer: Self.me) }
        }
    }

    @Test func unofficialFallbackHandlerIsRejected() {
        let r = Self.registration { $0.fallbackHandler = Self.attacker }
        #expect(throws: SafeAddress.VerificationError.unofficialFallbackHandler(Self.attacker)) { try SafeAddress.verify(r, signer: Self.me) }
        // 官方的，但版本不对（1.3.0 的 handler 配 1.4.1 的 singleton）；ExtensibleFallbackHandler 也不收。
        for h in ["0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4", "0x85a8ca358D388530ad0fB95D0cb89Dd44Fc242c3"] {
            let a = Address(hex: h)!
            #expect(throws: SafeAddress.VerificationError.unofficialFallbackHandler(a)) {
                try SafeAddress.verify(Self.registration { $0.fallbackHandler = a }, signer: Self.me)
            }
        }
    }

    /// 零地址和同版本官方 handler 照常通过。
    @Test func officialOrNoHandlerVerifies() throws {
        _ = try SafeAddress.verify(SafeAddressTests.sepoliaTestSafe, signer: Self.me)
        _ = try SafeAddress.verify(Self.registration { $0.fallbackHandler = .zero }, signer: Self.me)
        let v130 = Self.registration {
            $0.singleton = Address(hex: "0x3E5c63644E683549055b9Be8653de26E0B4CD36E")!
            $0.fallbackHandler = Address(hex: "0x017062a1dE2FE6b99BE3d9d37841FeD19F573804")!
        }
        #expect(try SafeAddress.verify(v130, signer: Self.me).initCode.version == "1.3.0")
    }

    /// 白名单覆盖每个 singleton 版本，并且每个地址在每条支持的链上都是标签库里的官方 CompatibilityFallbackHandler。
    @Test func whitelistMatchesLabelLibrary() {
        #expect(Set(SafeAddress.initCodes.map(\.version)) == Set(SafeAddress.compatibilityFallbackHandlers.keys))
        for (version, handlers) in SafeAddress.compatibilityFallbackHandlers {
            for h in handlers {
                for chain in SafeDeployments.supportedChains {
                    let e = LabelLibrary.builtIn.lookup(chainID: chain, address: h)
                    #expect(e?.kind == .safeFallbackHandler && e?.name.contains("CompatibilityFallbackHandler \(version)") == true, "\(h) on \(chain)")
                }
            }
        }
    }
}
