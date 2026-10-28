import CryptoKit
import Foundation

// 标准 UR 不覆盖的自定义类型：配对、Signer 签名回传、Safe 登记、带登记信息的签名请求。
// 类型名、键号、tag 定死在 docs/ur-types.md；只增不改，改了就换新的类型名。
// 解码一律从严：未知键、类型不对、取值越界都拒绝；可选字段取"空值"时必须省略（每个值只有一种编码）。

extension URTag {
    /// 自定义类型嵌入其它 CBOR 时用的 tag（IANA 先到先得区间，2026-10 时未被占用，尚未登记）。
    public static let unipassPairing: UInt64 = 41400
    public static let unipassSignature: UInt64 = 41401
    public static let unipassSafe: UInt64 = 41402
    public static let unipassSignRequest: UInt64 = 41403
}

/// Signer 密钥的 Face ID 策略。只给 Coordinator 做提示，不是安全控制。
public enum SignerBiometryPolicy: UInt64, Sendable {
    case anyEnrolled = 1
    case currentSet = 2
}

/// `unipass-pairing`：Signer → Coordinator，登记 Signer 的 owner 身份。
public struct SignerPairing: Hashable, Sendable {
    public static let urType = "unipass-pairing"

    /// P-256 公钥坐标，各 32 字节大端。
    public var x: Data
    public var y: Data
    public var name: String
    /// 调试用的软件密钥没有策略。
    public var biometryPolicy: SignerBiometryPolicy?
    /// `SafeWebAuthnSignerFactory.getSigner(x, y, verifiers)` 的结果，就是 Safe 里的 owner 地址。
    public var signerProxy: Address
    /// P256.Verifiers（uint176，22 字节：2 字节预编译地址 + 20 字节回退验证合约）。
    public var verifiers: Data
    public var signerFactory: Address

    /// 设备名最多 64 字节 UTF-8。
    public static let maxNameBytes = 64

    public init(x: Data, y: Data, name: String, biometryPolicy: SignerBiometryPolicy?,
                signerProxy: Address, verifiers: Data, signerFactory: Address) {
        self.x = x
        self.y = y
        self.name = name
        self.biometryPolicy = biometryPolicy
        self.signerProxy = signerProxy
        self.verifiers = verifiers
        self.signerFactory = signerFactory
    }

    public var cbor: CBOR {
        var pairs: [(CBOR, CBOR)] = [
            (.unsigned(1), .bytes(x)), (.unsigned(2), .bytes(y)), (.unsigned(3), .text(name)),
        ]
        if let biometryPolicy { pairs.append((.unsigned(4), .unsigned(biometryPolicy.rawValue))) }
        pairs += [(.unsigned(5), .bytes(signerProxy.bytes)), (.unsigned(6), .bytes(verifiers)),
                  (.unsigned(7), .bytes(signerFactory.bytes))]
        return .map(try! CBORMap(pairs))
    }

    public init(cbor: CBOR) throws {
        let f = try CBORFields(cbor, allowed: [1, 2, 3, 4, 5, 6, 7])
        guard let x = try f.bytes(1, count: 32...32) else { throw URTypeError.missingField(1) }
        guard let y = try f.bytes(2, count: 32...32) else { throw URTypeError.missingField(2) }
        guard let name = try f.text(3, maxBytes: Self.maxNameBytes) else { throw URTypeError.missingField(3) }
        guard !name.isEmpty else { throw URTypeError.invalidField(3) }
        var policy: SignerBiometryPolicy?
        if let p = try f.uint(4) {
            guard let v = SignerBiometryPolicy(rawValue: p) else { throw URTypeError.invalidField(4) }
            policy = v
        }
        guard let proxy = try f.address(5) else { throw URTypeError.missingField(5) }
        guard let verifiers = try f.bytes(6, count: 22...22) else { throw URTypeError.missingField(6) }
        guard let factory = try f.address(7) else { throw URTypeError.missingField(7) }
        self.init(x: x, y: y, name: name, biometryPolicy: policy, signerProxy: proxy, verifiers: verifiers,
                  signerFactory: factory)
    }

    public var ur: UR { try! UR(type: Self.urType, value: cbor) }

    public init(ur: UR) throws {
        guard ur.type == Self.urType else { throw URTypeError.wrongURType(expected: Self.urType, got: ur.type) }
        try self.init(cbor: ur.value)
    }

    /// 给 Signer 发 `eth-sign-request` 时 derivation-path 用 `{1: [], 2: 指纹}`（Signer 的密钥不是 BIP32 派生的）。
    /// 指纹 = SHA-256(0x04 ‖ x ‖ y) 的前 4 字节（大端）；规范要求非 0，算出 0 时用 1。
    /// 第三方钱包会在指纹核对这一步拒绝这种请求，这正是想要的。
    public static func keyFingerprint(x: Data, y: Data) -> UInt32 {
        let h = Array(SHA256.hash(data: Data([0x04]) + x + y))
        let fp = h[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return fp == 0 ? 1 : fp
    }

    public var keyFingerprint: UInt32 { Self.keyFingerprint(x: x, y: y) }

    /// 发给这台 Signer 的请求里应有的 derivation-path。
    public var requestKeypath: CryptoKeypath { CryptoKeypath(components: [], sourceFingerprint: keyFingerprint) }
}

/// `unipass-signature`：Signer → Coordinator，一次 WebAuthn 断言签名（格式见 docs/webauthn-signature.md）。
public struct SignerSignature: Hashable, Sendable {
    public static let urType = "unipass-signature"

    /// 回显请求里的 16 字节 request-id。
    public var requestID: Data
    public var assertion: WebAuthnAssertion
    /// 必须是 low-s（合约不检查 high-s，这是唯一的防线）。
    public var signature: P256Signature

    public static let maxClientDataFieldsBytes = 1024
    public static let maxAuthenticatorDataBytes = 1024

    public init(requestID: Data, assertion: WebAuthnAssertion, signature: P256Signature) {
        self.requestID = requestID
        self.assertion = assertion
        self.signature = signature
    }

    public var cbor: CBOR {
        .map(try! CBORMap([
            (.unsigned(1), .tagged(URTag.uuid, .bytes(requestID))),
            (.unsigned(2), .bytes(assertion.authenticatorData)),
            (.unsigned(3), .text(assertion.clientDataFields)),
            (.unsigned(4), .bytes(signature.r.bigEndianBytes)),
            (.unsigned(5), .bytes(signature.s.bigEndianBytes)),
        ]))
    }

    public init(cbor: CBOR) throws {
        let f = try CBORFields(cbor, allowed: [1, 2, 3, 4, 5])
        guard let requestID = try f.uuid(1) else { throw URTypeError.missingField(1) }
        // authenticatorData 至少 37 字节：rpIdHash(32) ‖ flags(1) ‖ signCount(4)。
        guard let authData = try f.bytes(2, count: 37...Self.maxAuthenticatorDataBytes) else { throw URTypeError.missingField(2) }
        guard let fields = try f.text(3, maxBytes: Self.maxClientDataFieldsBytes) else { throw URTypeError.missingField(3) }
        guard let r = try f.bytes(4, count: 32...32).flatMap({ UInt256(bigEndian: $0) }) else { throw URTypeError.missingField(4) }
        guard let s = try f.bytes(5, count: 32...32).flatMap({ UInt256(bigEndian: $0) }) else { throw URTypeError.missingField(5) }
        guard !r.isZero, r < P256Signature.curveOrder else { throw URTypeError.invalidField(4) }
        let sig = P256Signature(r: r, s: s)
        guard !s.isZero, sig.isLowS else { throw URTypeError.invalidField(5) }
        self.init(requestID: requestID, assertion: WebAuthnAssertion(authenticatorData: authData, clientDataFields: fields),
                  signature: sig)
    }

    /// 交给 `SafeWebAuthnSignerProxy` 的签名。
    public var proxySignature: Data { assertion.abiEncoded(signature: signature) }

    public var ur: UR { try! UR(type: Self.urType, value: cbor) }

    public init(ur: UR) throws {
        guard ur.type == Self.urType else { throw URTypeError.wrongURType(expected: Self.urType, got: ur.type) }
        try self.init(cbor: ur.value)
    }
}

/// `unipass-safe`：Coordinator → Signer，登记一个"我的 Safe"。带上创建时的 setup 参数，
/// Signer 离线用 CREATE2 重算地址核对，不信任 Coordinator 给的地址。
public struct SafeRegistration: Hashable, Sendable {
    public static let urType = "unipass-safe"

    public var chainID: UInt64
    public var safe: Address
    /// SafeProxyFactory。
    public var proxyFactory: Address
    /// Safe / SafeL2 singleton（master copy）。
    public var singleton: Address
    public var saltNonce: UInt256
    // 以下是 `Safe.setup(owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver)` 的参数。
    public var owners: [Address]
    public var threshold: UInt64
    public var to: Address
    public var data: Data
    public var fallbackHandler: Address
    public var paymentToken: Address
    public var payment: UInt256
    public var paymentReceiver: Address
    /// 用户给这个 Safe 起的名字（可选，只用于显示）。
    public var name: String?

    public static let maxOwners = 50
    public static let maxSetupDataBytes = 16 * 1024
    public static let maxNameBytes = 64

    public init(chainID: UInt64, safe: Address, proxyFactory: Address, singleton: Address, saltNonce: UInt256,
                owners: [Address], threshold: UInt64, to: Address = .zero, data: Data = Data(),
                fallbackHandler: Address, paymentToken: Address = .zero, payment: UInt256 = .zero,
                paymentReceiver: Address = .zero, name: String? = nil) {
        self.chainID = chainID
        self.safe = safe
        self.proxyFactory = proxyFactory
        self.singleton = singleton
        self.saltNonce = saltNonce
        self.owners = owners
        self.threshold = threshold
        self.to = to
        self.data = data
        self.fallbackHandler = fallbackHandler
        self.paymentToken = paymentToken
        self.payment = payment
        self.paymentReceiver = paymentReceiver
        self.name = name
    }

    public var cbor: CBOR {
        var pairs: [(CBOR, CBOR)] = [
            (.unsigned(1), .unsigned(chainID)),
            (.unsigned(2), .bytes(safe.bytes)),
            (.unsigned(3), .bytes(proxyFactory.bytes)),
            (.unsigned(4), .bytes(singleton.bytes)),
            (.unsigned(5), .bytes(saltNonce.bigEndianBytes)),
            (.unsigned(6), .array(owners.map { .bytes($0.bytes) })),
            (.unsigned(7), .unsigned(threshold)),
        ]
        // 取默认值（零地址 / 空 / 0）的字段省略，保证每个值只有一种编码。
        if to != .zero { pairs.append((.unsigned(8), .bytes(to.bytes))) }
        if !data.isEmpty { pairs.append((.unsigned(9), .bytes(data))) }
        pairs.append((.unsigned(10), .bytes(fallbackHandler.bytes)))
        if paymentToken != .zero { pairs.append((.unsigned(11), .bytes(paymentToken.bytes))) }
        if !payment.isZero { pairs.append((.unsigned(12), .bytes(payment.bigEndianBytes))) }
        if paymentReceiver != .zero { pairs.append((.unsigned(13), .bytes(paymentReceiver.bytes))) }
        if let name { pairs.append((.unsigned(14), .text(name))) }
        return .map(try! CBORMap(pairs))
    }

    public init(cbor: CBOR) throws {
        let f = try CBORFields(cbor, allowed: Set(1...14))
        guard let chainID = try f.uint(1), chainID > 0 else { throw URTypeError.invalidField(1) }
        guard let safe = try f.address(2) else { throw URTypeError.missingField(2) }
        guard let factory = try f.address(3) else { throw URTypeError.missingField(3) }
        guard let singleton = try f.address(4) else { throw URTypeError.missingField(4) }
        guard let salt = try f.bytes(5, count: 32...32).flatMap({ UInt256(bigEndian: $0) }) else { throw URTypeError.missingField(5) }
        guard let ownerItems = try f.required(6).arrayValue, (1...Self.maxOwners).contains(ownerItems.count) else {
            throw URTypeError.invalidField(6)
        }
        var owners: [Address] = []
        for item in ownerItems {
            // Safe 的 owner 不能是零地址、哨兵 0x…01，也不能重复。
            guard let d = item.bytesValue, let a = Address(bytes: d), a != .zero,
                  d != Data(repeating: 0, count: 19) + Data([1]), !owners.contains(a) else { throw URTypeError.invalidField(6) }
            owners.append(a)
        }
        guard let threshold = try f.uint(7), threshold >= 1, threshold <= UInt64(owners.count) else {
            throw URTypeError.invalidField(7)
        }
        let to = try f.address(8)
        if to == .zero { throw URTypeError.invalidField(8) }
        let data = try f.bytes(9, count: 1...Self.maxSetupDataBytes)
        guard let fallbackHandler = try f.address(10) else { throw URTypeError.missingField(10) }
        let paymentToken = try f.address(11)
        if paymentToken == .zero { throw URTypeError.invalidField(11) }
        let payment = try f.bytes(12, count: 32...32).map { UInt256(bigEndian: $0)! }
        if payment?.isZero == true { throw URTypeError.invalidField(12) }
        let paymentReceiver = try f.address(13)
        if paymentReceiver == .zero { throw URTypeError.invalidField(13) }
        let name = try f.text(14, maxBytes: Self.maxNameBytes)
        if name?.isEmpty == true { throw URTypeError.invalidField(14) }
        self.init(chainID: chainID, safe: safe, proxyFactory: factory, singleton: singleton, saltNonce: salt,
                  owners: owners, threshold: threshold, to: to ?? .zero, data: data ?? Data(),
                  fallbackHandler: fallbackHandler, paymentToken: paymentToken ?? .zero, payment: payment ?? .zero,
                  paymentReceiver: paymentReceiver ?? .zero, name: name)
    }

    public var ur: UR { try! UR(type: Self.urType, value: cbor) }

    public init(ur: UR) throws {
        guard ur.type == Self.urType else { throw URTypeError.wrongURType(expected: Self.urType, got: ur.type) }
        try self.init(cbor: ur.value)
    }
}

/// `unipass-sign-request`：Coordinator → Signer，一次扫码同时带上签名请求和这个 Safe 的登记信息。
/// 标准 `eth-sign-request` 原样嵌入（tag 401），不加字段；登记信息就是 `unipass-safe`（tag 41402）。
/// Signer 已经登记过这个 Safe 时忽略登记部分；没登记时先按 `SafeAddress.verify(_:signer:)` 核对、问用户，再看交易。
public struct SignRequestWithSafe: Hashable, Sendable {
    public static let urType = "unipass-sign-request"

    public var request: EthSignRequest
    public var registration: SafeRegistration

    public init(request: EthSignRequest, registration: SafeRegistration) {
        self.request = request
        self.registration = registration
    }

    public var cbor: CBOR {
        .map(try! CBORMap([
            (.unsigned(1), .tagged(URTag.ethSignRequest, request.cbor)),
            (.unsigned(2), .tagged(URTag.unipassSafe, registration.cbor)),
        ]))
    }

    public init(cbor: CBOR) throws {
        let f = try CBORFields(cbor, allowed: [1, 2])
        guard let req = try f.required(1).untagged(URTag.ethSignRequest) else { throw URTypeError.invalidField(1) }
        guard let reg = try f.required(2).untagged(URTag.unipassSafe) else { throw URTypeError.invalidField(2) }
        self.init(request: try EthSignRequest(cbor: req), registration: try SafeRegistration(cbor: reg))
    }

    public var ur: UR { try! UR(type: Self.urType, value: cbor) }

    public init(ur: UR) throws {
        guard ur.type == Self.urType else { throw URTypeError.wrongURType(expected: Self.urType, got: ur.type) }
        try self.init(cbor: ur.value)
    }

    /// 请求签的是不是登记的这个 Safe（同一条链、同一个地址）。请求解不出 SafeTx 时返回 nil，交给 RiskEngine 拒签。
    public var requestTargetsRegisteredSafe: Bool? {
        guard let tx = try? SafeTxRequest(signRequest: request) else { return nil }
        return tx.chainID == registration.chainID && tx.safe == registration.safe
    }
}
