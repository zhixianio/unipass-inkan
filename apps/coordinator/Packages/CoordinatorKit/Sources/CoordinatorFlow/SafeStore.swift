import Foundation
import UniPassCore

/// 这台 Mac 上的 Safe 列表：每个存完整的创建参数（`unipass-safe` 的 CBOR，和发给签名器的登记码同一种编码）
/// 和名字，外加当前选中的那个。创建或添加 Safe 时写入；签名器登记、提交账户的白名单都从这里读。
public struct SafeStore: Hashable, Sendable {
    public private(set) var safes: [SafeRegistration]
    public private(set) var selectedID: SafeID?

    /// 同一个地址在不同链上是不同的 Safe。
    public struct SafeID: Hashable, Codable, Sendable {
        public let chainID: UInt64
        public let address: String

        public init(_ r: SafeRegistration) {
            chainID = r.chainID
            address = r.safe.checksummed
        }
    }

    public init(safes: [SafeRegistration] = [], selectedID: SafeID? = nil) {
        self.safes = safes
        self.selectedID = selectedID
    }

    /// 当前选中的 Safe；没选过就用第一个。
    public var current: SafeRegistration? {
        safes.first { SafeID($0) == selectedID } ?? safes.first
    }

    /// 加入（已有同一个 Safe 时替换），并选中它。
    public mutating func add(_ r: SafeRegistration) {
        safes.removeAll { SafeID($0) == SafeID(r) }
        safes.append(r)
        selectedID = SafeID(r)
    }

    public mutating func remove(_ id: SafeID) {
        safes.removeAll { SafeID($0) == id }
        if selectedID == id { selectedID = safes.first.map(SafeID.init) }
    }

    public mutating func select(_ id: SafeID) {
        if safes.contains(where: { SafeID($0) == id }) { selectedID = id }
    }

    public func contains(chainID: UInt64, address: Address) -> Bool {
        safes.contains { $0.chainID == chainID && $0.safe == address }
    }

    // MARK: 存储格式

    private struct Stored: Codable {
        var version = 1
        /// 每个 Safe 的 `unipass-safe` CBOR（十六进制）。
        var safes: [String]
        var selected: SafeID?
    }

    public enum DecodingError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidHex
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(Stored(safes: safes.map { $0.ur.cbor.hexString }, selected: selectedID))
    }

    public init(decoding data: Data) throws {
        let s = try JSONDecoder().decode(Stored.self, from: data)
        guard s.version == 1 else { throw DecodingError.unsupportedVersion(s.version) }
        let safes = try s.safes.map { hex -> SafeRegistration in
            guard let cbor = Data(hex: hex) else { throw DecodingError.invalidHex }
            return try SafeRegistration(ur: try UR(type: SafeRegistration.urType, cbor: cbor))
        }
        self.init(safes: safes, selectedID: s.selected)
    }
}

extension SafeRegistration {
    /// 生成登记二维码之前先用 core 自己核对一遍（和 Signer 离线做的是同一个检查）。
    public func verified() throws -> SafeAddress.InitCode {
        try SafeAddress.verify(self)
    }
}
