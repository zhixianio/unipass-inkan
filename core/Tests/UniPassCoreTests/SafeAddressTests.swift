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
