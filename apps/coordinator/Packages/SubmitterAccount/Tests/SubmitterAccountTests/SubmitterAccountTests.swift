import Foundation
import Testing
import UniPassCore
@testable import SubmitterAccount

/// 对照向量来自 Foundry：`cast mktx --private-key <下面的公开示例私钥> --chain 11155111 …`
/// （web3.js 文档里的示例私钥，地址 0x2c7536E3605D9C16a7a3D7b1898e529396a65c23，不对应任何资产）。
enum Vectors {
    static let privateKey = Data(hex: "0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")!
    static let address = Address(hex: "0x2c7536E3605D9C16a7a3D7b1898e529396a65c23")!

    /// 转 0.001 ETH：nonce 7，gas 21000，maxFee 2 gwei，tip 1 gwei。
    static let transfer = EIP1559Transaction(
        chainID: 11_155_111, nonce: 7, maxPriorityFeePerGas: UInt256(1_000_000_000), maxFeePerGas: UInt256(2_000_000_000),
        gasLimit: 21_000, to: Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!, value: UInt256(1_000_000_000_000_000))
    static let transferRaw = Data(hex: "0x02f87483aa36a707843b9aca00847735940082520894938313a557b6129d2d8cbda84ad962b1869ab39a87038d7ea4c6800080c080a0aeb6cadabdcf891b495aba1e7c384d12ed435079c728890469fdd5a1c80087b2a04a1e5a78b52a1b4e1a2e10197f25ede33ac561407d768360b772b6cbd03966c3")!

    /// 调用 Safe，100 字节 calldata（RLP 长字符串）：nonce 300，gas 250000，maxFee 30.000000014 gwei，tip 0.045 gwei。
    static let call = EIP1559Transaction(
        chainID: 11_155_111, nonce: 300, maxPriorityFeePerGas: UInt256(45_000_000), maxFeePerGas: UInt256(30_000_000_014),
        gasLimit: 250_000, to: Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!, data: Data((0..<100).map { UInt8($0) }))
    static let callRaw = Data(hex: "0x02f8d683aa36a782012c8402aea5408506fc23ac0e8303d090948ceb01112162b035be3d38740f8233d28da0e4a180b864000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60616263c001a09d007af3692a60bbc1a852d5aced11a6866177c84e469d530ef1ecadf69ce954a01d535fe84ce8ea3d337059893f7100430c562020beabdbc4b7d6550d0dd31a71")!

    /// 原始交易末尾的签名：… yParity(1 字节) ‖ 0xa0 ‖ r ‖ 0xa0 ‖ s。
    static func signature(of raw: Data) -> RecoverableSignature {
        let b = [UInt8](raw)
        let v = b[b.count - 67]
        return RecoverableSignature(r: Data(b[(b.count - 65)..<(b.count - 33)]), s: Data(b[(b.count - 32)...]), yParity: v == 0x80 ? 0 : v)
    }
}

@Suite struct RLPTests {
    @Test func basics() {
        #expect(RLP.bytes(Data()).encoded == Data([0x80]))
        #expect(RLP.bytes(Data([0x00])).encoded == Data([0x00]))
        #expect(RLP.bytes(Data([0x7f])).encoded == Data([0x7f]))
        #expect(RLP.bytes(Data([0x80])).encoded == Data([0x81, 0x80]))
        #expect(RLP.bytes(Data("dog".utf8)).encoded == Data([0x83]) + Data("dog".utf8))
        #expect(RLP.uint(UInt64(0)).encoded == Data([0x80]))
        #expect(RLP.uint(UInt64(1024)).encoded == Data([0x82, 0x04, 0x00]))
        #expect(RLP.list([]).encoded == Data([0xc0]))
        #expect(RLP.list([.bytes(Data("cat".utf8)), .bytes(Data("dog".utf8))]).encoded
            == Data([0xc8, 0x83]) + Data("cat".utf8) + Data([0x83]) + Data("dog".utf8))
        // 56 字节：长字符串
        let long = Data(repeating: 0x61, count: 56)
        #expect(RLP.bytes(long).encoded == Data([0xb8, 56]) + long)
        let longer = Data(repeating: 0x61, count: 1024)
        #expect(RLP.bytes(longer).encoded.prefix(3) == Data([0xb9, 0x04, 0x00]))
    }
}

@Suite struct EIP1559Tests {
    @Test func encodesLikeFoundry() {
        #expect(Vectors.transfer.raw(Vectors.signature(of: Vectors.transferRaw)) == Vectors.transferRaw)
        #expect(Vectors.call.raw(Vectors.signature(of: Vectors.callRaw)) == Vectors.callRaw)
    }

    @Test func maxCost() {
        // 0.001 ETH + 21000 × 2 gwei
        #expect(Vectors.transfer.maxCost == UInt256(1_000_000_000_000_000 + 21_000 * 2_000_000_000))
    }

    @Test func fees() throws {
        let f = try SubmitterAccount.fees(baseFee: UInt256(14), tip: UInt256(3))
        #expect(f.tip == UInt256(1_000_000) && f.max == UInt256(1_000_028) && f.expected == UInt256(1_000_014))
        let g = try SubmitterAccount.fees(baseFee: UInt256(10_000_000_000), tip: UInt256(2_000_000_000))
        #expect(g.tip == UInt256(2_000_000_000) && g.max == UInt256(22_000_000_000))
    }
}

@Suite struct SigningPolicyTests {
    let safe = Address(hex: "0x8ceb01112162b035BE3D38740f8233d28DA0E4a1")!
    let other = Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!
    var policy: SigningPolicy { SigningPolicy(safes: [.init(chainID: 11_155_111, address: safe)]) }

    func tx(to: Address, data: Data = Data(), value: UInt256 = .zero) -> EIP1559Transaction {
        EIP1559Transaction(chainID: 11_155_111, nonce: 0, maxPriorityFeePerGas: UInt256(1), maxFeePerGas: UInt256(2),
                           gasLimit: data.isEmpty ? 21_000 : 100_000, to: to, value: value, data: data)
    }

    // MARK: 创建 Safe 的批量（MultiSendCallOnly）

    static let safeL2 = Address(hex: "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")!

    static func word(_ n: Int) -> Data { UInt256(UInt64(n)).bigEndianBytes }

    static func entry(_ to: Address, _ data: Data, operation: UInt8 = 0, value: Int = 0) -> Data {
        Data([operation]) + to.bytes + word(value) + word(data.count) + data
    }

    static func batch(_ entries: [Data], offset: Int = 32, padding: UInt8 = 0) -> Data {
        let packed = entries.reduce(Data(), +)
        return SigningPolicy.multiSend + word(offset) + word(packed.count) + packed + Data(repeating: padding, count: (32 - packed.count % 32) % 32)
    }

    static let createSigner = SigningPolicy.createSigner + Data(repeating: 1, count: 96)

    static let attacker = Address(hex: "0x00000000000000000000000000000000000BAD00")!

    /// 桌面端正常创建的参数：SafeL2 1.4.1、1.4.1 的 CompatibilityFallbackHandler、setup 不带额外调用和付款。
    static func setup(_ change: (inout SafeRegistration) -> Void = { _ in }) -> SafeRegistration {
        var r = SafeRegistration(chainID: 11_155_111, safe: .zero, proxyFactory: SigningPolicy.proxyFactory141, singleton: safeL2,
                                 saltNonce: UInt256(7), owners: [Address(hex: "0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06")!],
                                 threshold: 1, fallbackHandler: Address(hex: "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99")!)
        change(&r)
        return r
    }

    /// `createProxyWithNonce(singleton, initializer, saltNonce)`，标准编码。
    static func createProxy(singleton: Address = safeL2, initializer: Data = SafeAddress.setupCalldata(setup())) -> Data {
        SigningPolicy.createProxyWithNonce + singleton.abiEncoded + word(96) + word(7) + word(initializer.count)
            + initializer + Data(count: (32 - initializer.count % 32) % 32)
    }

    static func creating(_ initializer: Data) -> Data {
        batch([entry(SigningPolicy.signerFactory, createSigner), entry(SigningPolicy.proxyFactory141, createProxy(initializer: initializer))])
    }

    func deploy(_ data: Data) -> EIP1559Transaction { tx(to: SigningPolicy.multiSendCallOnly141, data: data) }

    @Test func allowed() throws {
        try policy.check(tx(to: other, value: UInt256(5))) // 转出余额
        try policy.check(tx(to: safe, data: SigningPolicy.execTransaction + Data(count: 64)))
        try policy.check(deploy(Self.batch([Self.entry(SigningPolicy.signerFactory, Self.createSigner),
                                            Self.entry(SigningPolicy.proxyFactory141, Self.createProxy())])))
        try policy.check(deploy(Self.batch([Self.entry(SigningPolicy.proxyFactory141, Self.createProxy())])))
        #expect(SigningPolicy.execTransaction.hexString == "0x6a761202")
        #expect(SigningPolicy.multiSend.hexString == "0x8d80ff0a")
        #expect(SigningPolicy.createSigner.hexString == "0x0d2f0489")
        #expect(SigningPolicy.createProxyWithNonce.hexString == "0x1688f0b9")
    }

    /// 发往 MultiSendCallOnly 的批量里只要有一项不是创建签名器或创建 Safe，整笔都拒签。
    @Test func refusesOtherBatches() {
        let signer = Self.entry(SigningPolicy.signerFactory, Self.createSigner)
        let safeEntry = Self.entry(SigningPolicy.proxyFactory141, Self.createProxy())
        let approve = Data(hex: "0x095ea7b3")! + Data(count: 64)
        for data in [
            SigningPolicy.multiSend + Data(count: 64), // 空批量
            Self.batch([signer, Self.entry(other, approve)]), // 夹带代币授权
            Self.batch([Self.entry(SigningPolicy.proxyFactory141, Self.createProxy(), operation: 1)]), // DELEGATECALL
            Self.batch([Self.entry(SigningPolicy.signerFactory, Self.createSigner, value: 1)]), // 带 value
            Self.batch([Self.entry(SigningPolicy.signerFactory, approve)]), // 工厂的其他函数
            Self.batch([Self.entry(SigningPolicy.proxyFactory141, Self.createProxy(singleton: other))]), // 不是官方 singleton
            Self.batch([Self.entry(other, Self.createProxy())]), // 别的"factory"
            Self.batch([signer, safeEntry], offset: 64), // 不规范的偏移
            Self.batch([signer], padding: 1), // 补齐的字节不是 0
            Self.batch([signer, safeEntry]).dropLast(32), // 截断
        ] {
            #expect(throws: SigningPolicy.Violation.notAllowed) { try policy.check(deploy(Data(data))) }
        }
        #expect(throws: SigningPolicy.Violation.notAllowed) {
            try policy.check(tx(to: SigningPolicy.multiSendCallOnly141, data: Self.batch([signer]), value: UInt256(1)))
        }
    }

    /// 创建 Safe 的 initializer 要和签名器登记时一样核对：被控制的桌面端可以让 owner 和门限看起来都对，
    /// 却在 setup 里 DELEGATECALL 攻击者合约（偷加 module 或 owner），或者装一个会替 Safe "认可"任何签名的 fallback handler。
    @Test func refusesUnsafeSetup() {
        for r in [
            Self.setup { $0.to = Self.attacker; $0.data = Data([0xde, 0xad, 0xbe, 0xef]) }, // setup 里 DELEGATECALL 攻击者合约
            Self.setup { $0.to = Self.attacker }, // 只有 to
            Self.setup { $0.data = Data([0x01]) }, // 只有 data
            Self.setup { $0.payment = UInt256(1); $0.paymentReceiver = Self.attacker },
            Self.setup { $0.paymentToken = Self.attacker },
            Self.setup { $0.paymentReceiver = Self.attacker },
            Self.setup { $0.fallbackHandler = Self.attacker }, // 非官方 fallback handler
            Self.setup { $0.fallbackHandler = Address(hex: "0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4")! }, // 官方的，但是 1.3.0 的
        ] {
            #expect(throws: SigningPolicy.Violation.notAllowed) { try policy.check(deploy(Self.creating(SafeAddress.setupCalldata(r)))) }
        }
    }

    /// initializer 必须是 `Safe.setup`，两层的编码都必须规范：重新编码要逐字节一致。
    @Test func refusesOtherInitializers() {
        let good = SafeAddress.setupCalldata(Self.setup())
        // owners 的偏移改成 0x120，后面整体挪一个字：Solidity 照样能解，但不是规范编码。
        var shifted = Data(good.prefix(4)) + Self.word(0x120) + good[36..<100] + Self.word(0x140 + 32 * 1) + good[132..<260]
        shifted += Data(count: 32) + good[260...]
        let enableModule = Data(Keccak.hash256(Data("enableModule(address)".utf8)).prefix(4)) + Self.attacker.abiEncoded
        for initializer in [
            Data(repeating: 2, count: 100), // 不是 setup
            enableModule,
            Data(), // 空的
            good.prefix(good.count - 32), // 截断
            good + Data(count: 32), // 末尾多一个字
            shifted,
            Data(good.prefix(4 + 32 * 2)) + Data([0x01]) + good[(4 + 32 * 2 + 1)...], // 地址高位不是 0
        ] {
            #expect(throws: SigningPolicy.Violation.notAllowed) { try policy.check(deploy(Self.creating(initializer))) }
        }
        // createProxyWithNonce 本身不规范：bytes 的偏移不是 0x60、补齐不是 0、末尾多字节。
        let proxy = Self.createProxy()
        var offset128: Data = SigningPolicy.createProxyWithNonce + Self.safeL2.abiEncoded + Self.word(128) + Self.word(7)
        offset128 += Data(count: 32) + Self.word(good.count) + good + Data(count: (32 - good.count % 32) % 32)
        let badPadding: Data = proxy.prefix(proxy.count - 1) + Data([1])
        for data in [offset128, badPadding, proxy + Data(count: 32)] {
            #expect(throws: SigningPolicy.Violation.notAllowed) {
                try policy.check(deploy(Self.batch([Self.entry(SigningPolicy.proxyFactory141, data)])))
            }
        }
    }

    /// 桌面端正常创建的批量照常通过：零地址 handler、多个 owner、各版本官方 handler 配对应版本的 singleton。
    @Test func allowsNormalCreation() throws {
        try policy.check(deploy(Self.creating(SafeAddress.setupCalldata(Self.setup()))))
        try policy.check(deploy(Self.creating(SafeAddress.setupCalldata(Self.setup { $0.fallbackHandler = .zero }))))
        try policy.check(deploy(Self.creating(SafeAddress.setupCalldata(Self.setup { $0.owners.append(Self.attacker); $0.threshold = 2 }))))
        let safe141 = Address(hex: "0x41675C099F32341bf84BFc5382aF534df5C7461a")!
        try policy.check(deploy(Self.batch([Self.entry(SigningPolicy.proxyFactory141, Self.createProxy(singleton: safe141))])))
    }

    @Test func refused() {
        let exec = SigningPolicy.execTransaction + Data(count: 64)
        let approve = Data(hex: "0x095ea7b3")! + Data(count: 64)
        for t in [
            tx(to: other, data: exec), // 没登记的"Safe"
            tx(to: safe, data: exec, value: UInt256(1)), // 带 value
            tx(to: safe, data: approve), // 其他调用
            tx(to: other, data: approve), // 代币授权
            tx(to: safe, data: Data([0x6a, 0x76])), // 不足 4 字节
            tx(to: other, data: Self.batch([Self.entry(SigningPolicy.signerFactory, Self.createSigner)])), // 不是规范的 MultiSendCallOnly
        ] {
            #expect(throws: SigningPolicy.Violation.notAllowed) { try policy.check(t) }
        }
    }

    /// type-4 交易和 7702 授权在算哈希之前就被拒绝。
    @Test func onlyType2Payloads() throws {
        try SigningPayload.validate(Data([0x02, 0xc0]))
        for first: UInt8 in [0x00, 0x01, 0x03, 0x04, 0x05, 0xf8] {
            #expect(throws: SigningPayload.Rejected.unsupportedType(first)) { try SigningPayload.validate(Data([first, 0xc0])) }
        }
        #expect(throws: SigningPayload.Rejected.unsupportedType(nil)) { try SigningPayload.validate(Data()) }
    }
}

@Suite struct Secp256k1Tests {
    @Test func addressFromPrivateKey() throws {
        #expect(try Secp256k1Key(Vectors.privateKey).address == Vectors.address)
    }

    /// RFC 6979 确定性签名：和 Foundry 签出来的逐字节一致。
    @Test func signsLikeFoundry() throws {
        let key = try Secp256k1Key(Vectors.privateKey)
        #expect(Vectors.transfer.raw(try key.sign(payload: Vectors.transfer.signingPayload)) == Vectors.transferRaw)
        #expect(Vectors.call.raw(try key.sign(payload: Vectors.call.signingPayload)) == Vectors.callRaw)
        // 普通转账在白名单里，经账户签出来也一样。
        let account = SubmitterAccount(key: key, policy: SigningPolicy(safes: []))
        #expect(try account.signed(Vectors.transfer) == Vectors.transferRaw)
    }

    /// 私钥这一层拒绝 type-4 交易和 EIP-7702 授权。
    @Test func refusesEIP7702AtTheKey() throws {
        let key = try Secp256k1Key(Vectors.privateKey)
        let authorization = Data([0x05]) + RLP.list([.uint(UInt64(11_155_111)), .bytes(Vectors.address.bytes), .uint(UInt64(0))]).encoded
        #expect(throws: SigningPayload.Rejected.unsupportedType(0x05)) { try key.sign(payload: authorization) }
        let setCode = Data([0x04]) + Vectors.transfer.signingPayload.dropFirst()
        #expect(throws: SigningPayload.Rejected.unsupportedType(0x04)) { try key.sign(payload: setCode) }
    }

    @Test func accountRefusesCallsOutsideThePolicy() throws {
        let account = SubmitterAccount(key: try Secp256k1Key(Vectors.privateKey),
                                       policy: SigningPolicy(safes: [.init(chainID: 11_155_111, address: Vectors.call.to)]))
        #expect(throws: SigningPolicy.Violation.notAllowed) { try account.signed(Vectors.call) } // 不是 execTransaction
    }

    @Test func rejectsInvalidKeys() {
        #expect(throws: (any Error).self) { try Secp256k1Key(Data(count: 32)) }
        #expect(throws: (any Error).self) { try Secp256k1Key(Data(repeating: 0xff, count: 32)) }
    }

    @Test func generatesDistinctKeys() throws {
        #expect(try Secp256k1Key.generate().address != Secp256k1Key.generate().address)
    }
}
