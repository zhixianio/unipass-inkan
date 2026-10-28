import Foundation

// EIP-4527 的 `eth-sign-request`，以及它引用的 `crypto-keypath`。签名回传用自定义的 `unipass-signature`，不实现 `eth-signature`。
// 键号、tag 和各家钱包的实际行为见 docs/ur-types.md。

/// 把 CBOR 映射按"只允许这些键"读出来；出现别的键就拒绝（和 Keycard Shell 一样严）。
struct CBORFields {
    let map: CBORMap

    init(_ cbor: CBOR, allowed: Set<UInt64>) throws {
        guard let map = cbor.mapValue else { throw URTypeError.notAMap }
        for e in map.entries {
            guard let k = e.key.uint, allowed.contains(k) else { throw URTypeError.unknownKey }
        }
        self.map = map
    }

    func optional(_ key: Int) -> CBOR? { map[key] }

    func required(_ key: Int) throws -> CBOR {
        guard let v = map[key] else { throw URTypeError.missingField(key) }
        return v
    }

    func bytes(_ key: Int, count: ClosedRange<Int>) throws -> Data? {
        guard let v = optional(key) else { return nil }
        guard let d = v.bytesValue, count.contains(d.count) else { throw URTypeError.invalidField(key) }
        return d
    }

    func text(_ key: Int, maxBytes: Int) throws -> String? {
        guard let v = optional(key) else { return nil }
        guard let s = v.textValue, s.utf8.count <= maxBytes else { throw URTypeError.invalidField(key) }
        return s
    }

    func uint(_ key: Int, max: UInt64 = .max) throws -> UInt64? {
        guard let v = optional(key) else { return nil }
        guard let n = v.uint, n <= max else { throw URTypeError.invalidField(key) }
        return n
    }

    func address(_ key: Int) throws -> Address? {
        try bytes(key, count: 20...20).map { Address(bytes: $0)! }
    }

    /// `#6.37(bytes .size 16)`。
    func uuid(_ key: Int) throws -> Data? {
        guard let v = optional(key) else { return nil }
        guard let d = v.untagged(URTag.uuid)?.bytesValue, d.count == 16 else { throw URTypeError.invalidField(key) }
        return d
    }
}

public enum URTypeError: Error, Hashable, Sendable {
    case wrongURType(expected: String, got: String)
    case notAMap
    case unknownKey
    case missingField(Int)
    case invalidField(Int)
}

public enum URTag {
    public static let uuid: UInt64 = 37
    /// crypto-keypath v1。EIP-4527 生态（Keystone、Keycard、OneKey）只认这个，所以编码时用它。
    public static let cryptoKeypath: UInt64 = 304
    /// BCR-2020-006 的 v2 `keypath`；只在读的时候接受。
    public static let keypathV2: UInt64 = 40304
    public static let ethSignRequest: UInt64 = 401
}

/// BIP32 派生路径（`crypto-keypath`）。只支持单个下标和通配符；范围形式拒绝。
public struct CryptoKeypath: Hashable, Sendable {
    public enum Index: Hashable, Sendable {
        case index(UInt32)
        case wildcard
    }

    public struct Component: Hashable, Sendable {
        public var index: Index
        public var hardened: Bool
        public init(_ index: Index, hardened: Bool) {
            self.index = index
            self.hardened = hardened
        }
    }

    public var components: [Component]
    public var sourceFingerprint: UInt32?
    public var depth: UInt8?

    /// Keycard Shell 最多接受 10 段；我们放宽到 16，再多就是异常输入。
    public static let maxComponents = 16

    public init(components: [Component], sourceFingerprint: UInt32?, depth: UInt8? = nil) {
        self.components = components
        self.sourceFingerprint = sourceFingerprint
        self.depth = depth
    }

    /// `m/44'/60'/0'/0/1` 风格；不支持通配符。
    public init?(path: String, sourceFingerprint: UInt32?) {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first?.lowercased() == "m" { parts.removeFirst() }
        var components: [Component] = []
        for p in parts {
            let hardened = p.hasSuffix("'") || p.hasSuffix("h")
            guard let n = UInt32(hardened ? p.dropLast() : p), n < 0x8000_0000 else { return nil }
            components.append(Component(.index(n), hardened: hardened))
        }
        self.init(components: components, sourceFingerprint: sourceFingerprint)
    }

    public var cbor: CBOR {
        var pairs: [(CBOR, CBOR)] = [(.unsigned(1), .array(components.flatMap { c -> [CBOR] in
            switch c.index {
            case .index(let n): [.unsigned(UInt64(n)), .bool(c.hardened)]
            case .wildcard: [.array([]), .bool(c.hardened)]
            }
        }))]
        if let fp = sourceFingerprint { pairs.append((.unsigned(2), .unsigned(UInt64(fp)))) }
        if let depth { pairs.append((.unsigned(3), .unsigned(UInt64(depth)))) }
        return .map(try! CBORMap(pairs))
    }

    public init(cbor: CBOR) throws {
        let f = try CBORFields(cbor, allowed: [1, 2, 3])
        guard let items = try f.required(1).arrayValue, items.count % 2 == 0,
              items.count / 2 <= Self.maxComponents else { throw URTypeError.invalidField(1) }
        var components: [Component] = []
        for i in stride(from: 0, to: items.count, by: 2) {
            guard let hardened = items[i + 1].boolValue else { throw URTypeError.invalidField(1) }
            if let n = items[i].uint, n < 0x8000_0000 {
                components.append(Component(.index(UInt32(n)), hardened: hardened))
            } else if items[i] == .array([]) {
                components.append(Component(.wildcard, hardened: hardened))
            } else {
                throw URTypeError.invalidField(1)
            }
        }
        let fp = try f.uint(2, max: UInt64(UInt32.max))
        if fp == 0 { throw URTypeError.invalidField(2) }
        // 规范：components 为空时 source-fingerprint 必须存在（主密钥指纹）。
        if components.isEmpty, fp == nil { throw URTypeError.missingField(2) }
        self.init(components: components, sourceFingerprint: fp.map(UInt32.init),
                  depth: try f.uint(3, max: UInt64(UInt8.max)).map(UInt8.init))
    }

    /// 嵌入时的形式：`#6.304(...)`。读的时候也接受 40304。
    var taggedCBOR: CBOR { .tagged(URTag.cryptoKeypath, cbor) }

    init(taggedCBOR: CBOR) throws {
        guard case .tagged(let tag, let inner) = taggedCBOR, tag == URTag.cryptoKeypath || tag == URTag.keypathV2 else {
            throw URTypeError.invalidField(5)
        }
        try self.init(cbor: inner)
    }
}

/// EIP-4527 `eth-sign-request`。
public struct EthSignRequest: Hashable, Sendable {
    public static let urType = "eth-sign-request"

    public enum DataType: UInt64, Sendable {
        /// 传统交易的 RLP。
        case transaction = 1
        /// EIP-712 typed data 的 JSON 字节。
        case typedData = 2
        /// EIP-191 personal_sign 的原始消息。
        case personalMessage = 3
        /// EIP-2718 typed transaction。
        case typedTransaction = 4
    }

    /// 16 字节 UUID。规范里是可选的，但 AirGap 没有它会崩，所以我们发出的请求总是带上。
    public var requestID: Data?
    public var signData: Data
    public var dataType: DataType
    public var chainID: UInt64?
    public var derivationPath: CryptoKeypath
    public var address: Address?
    public var origin: String?

    public init(requestID: Data?, signData: Data, dataType: DataType, chainID: UInt64?,
                derivationPath: CryptoKeypath, address: Address? = nil, origin: String? = nil) {
        self.requestID = requestID
        self.signData = signData
        self.dataType = dataType
        self.chainID = chainID
        self.derivationPath = derivationPath
        self.address = address
        self.origin = origin
    }

    public var cbor: CBOR {
        var pairs: [(CBOR, CBOR)] = []
        if let requestID { pairs.append((.unsigned(1), .tagged(URTag.uuid, .bytes(requestID)))) }
        pairs.append((.unsigned(2), .bytes(signData)))
        pairs.append((.unsigned(3), .unsigned(dataType.rawValue)))
        if let chainID { pairs.append((.unsigned(4), .unsigned(chainID))) }
        pairs.append((.unsigned(5), derivationPath.taggedCBOR))
        if let address { pairs.append((.unsigned(6), .bytes(address.bytes))) }
        if let origin { pairs.append((.unsigned(7), .text(origin))) }
        return .map(try! CBORMap(pairs))
    }

    public init(cbor: CBOR) throws {
        let f = try CBORFields(cbor, allowed: [1, 2, 3, 4, 5, 6, 7])
        guard let signData = try f.required(2).bytesValue, !signData.isEmpty else { throw URTypeError.invalidField(2) }
        // data-type 实际上是裸整数（EIP 文本里的 #3.401 是笔误，见 docs/ur-types.md）。
        guard let dt = try f.required(3).uint, let dataType = DataType(rawValue: dt) else { throw URTypeError.invalidField(3) }
        self.init(
            requestID: try f.uuid(1),
            signData: signData,
            dataType: dataType,
            chainID: try f.uint(4),
            derivationPath: try CryptoKeypath(taggedCBOR: f.required(5)),
            address: try f.address(6),
            origin: try f.text(7, maxBytes: 256)
        )
    }

    public var ur: UR { try! UR(type: Self.urType, value: cbor) }

    public init(ur: UR) throws {
        guard ur.type == Self.urType else { throw URTypeError.wrongURType(expected: Self.urType, got: ur.type) }
        try self.init(cbor: ur.value)
    }
}
