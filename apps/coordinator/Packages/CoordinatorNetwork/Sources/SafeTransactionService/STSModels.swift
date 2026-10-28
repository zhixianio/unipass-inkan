import Foundation
import UniPassCore

/// Safe 托管 STS 支持的链。路径里用 EIP-3770 短名：`https://api.safe.global/tx-service/<shortName>`。
public struct SafeChain: Hashable, Sendable {
    public let shortName: String
    public let chainId: UInt64

    public init(shortName: String, chainId: UInt64) {
        self.shortName = shortName
        self.chainId = chainId
    }

    public static let mainnet = SafeChain(shortName: "eth", chainId: 1)
    public static let sepolia = SafeChain(shortName: "sep", chainId: 11_155_111)
    public static let base = SafeChain(shortName: "base", chainId: 8453)
    public static let optimism = SafeChain(shortName: "oeth", chainId: 10)

    public static let known: [SafeChain] = [.mainnet, .sepolia, .base, .optimism]

    /// Safe 托管的 STS。自托管时直接传自己的 base URL 给 `STSClient`。
    public var hostedBaseURL: URL {
        URL(string: "https://api.safe.global/tx-service/\(shortName)")!
    }
}

/// `GET /api/v1/about/`
public struct STSAbout: Decodable, Sendable {
    public let name: String
    public let version: String
    public let apiVersion: String?

    enum CodingKeys: String, CodingKey {
        case name, version
        case apiVersion = "api_version"
    }
}

/// `GET /api/v1/safes/{address}/`
public struct SafeInfo: Decodable, Hashable, Sendable {
    public let address: String
    public let nonce: STSUInt
    public let threshold: Int
    public let owners: [String]
    public let masterCopy: String
    public let modules: [String]
    public let fallbackHandler: String
    public let `guard`: String
    public let version: String?
}

/// `GET /api/v1/safes/{address}/creation/`。只取重算地址需要的字段，其余（`dataDecoded` 等）不信也不用。
public struct SafeCreationInfo: Decodable, Hashable, Sendable {
    public let transactionHash: String?
    public let factoryAddress: String?
    public let masterCopy: String?
    public let setupData: String?
    public let saltNonce: String?
}

public struct STSPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let count: Int?
    public let next: String?
    public let previous: String?
    public let results: [Item]
}

/// `GET /api/v2/safes/{address}/multisig-transactions/` 的一项。
public struct MultisigTransaction: Decodable, Hashable, Sendable {
    public let safe: String
    public let to: String
    public let value: STSUInt
    public let data: String?
    public let operation: Int
    public let gasToken: String?
    public let safeTxGas: STSUInt
    public let baseGas: STSUInt
    public let gasPrice: STSUInt
    public let refundReceiver: String?
    public let nonce: STSUInt
    public let safeTxHash: String
    public let proposer: String?
    public let isExecuted: Bool
    public let transactionHash: String?
    public let confirmationsRequired: Int
    public let confirmations: [Confirmation]?
    public let trusted: Bool?
    public let submissionDate: String?
    public let executionDate: String?
    /// 上链后执行是否成功（Safe 的 ExecutionSuccess / ExecutionFailure）。
    public let isSuccessful: Bool?

    public struct Confirmation: Decodable, Hashable, Sendable {
        public let owner: String
        public let signature: String?
        /// `EOA` / `ETH_SIGN` / `APPROVED_HASH` / `CONTRACT_SIGNATURE`
        public let signatureType: String?
        public let submissionDate: String?
    }

    /// STS 收集到的确认 → core 的 owner 签名，再用 `SafeSignatures.encode` 拼成 `execTransaction` 的 `signatures`
    /// （STS 在执行前不返回拼好的 `signatures`）。
    ///
    /// EOA / ETH_SIGN 的签名就是 65 字节；CONTRACT_SIGNATURE 存的是单个 owner 的 Safe 格式签名
    /// （`r = owner, s = offset, v = 0` ‖ 长度 ‖ 数据），这里取出数据部分。
    public func ownerSignatures() throws -> [SafeOwnerSignature] {
        try (confirmations ?? []).map { c in
            guard let owner = Address(hex: c.owner.lowercased()),
                  let raw = c.signature.flatMap({ Data(hex: $0) })
            else { throw STSError.invalidField("confirmation \(c.owner)") }
            switch c.signatureType {
            case "EOA", "ETH_SIGN":
                return .eoa(owner: owner, signature: raw)
            case "CONTRACT_SIGNATURE":
                return .contract(owner: owner, signature: try Self.contractData(raw, owner: owner))
            default:
                throw STSError.invalidField("signatureType \(c.signatureType ?? "nil")")
            }
        }
    }

    static func contractData(_ raw: Data, owner: Address) throws -> Data {
        let b = [UInt8](raw)
        guard b.count >= 97, Data(b[12..<32]) == owner.bytes, b[64] == 0,
              let offset = UInt256(bigEndian: Data(b[32..<64])), offset.words[1...].allSatisfy({ $0 == 0 }),
              Int(offset.words[0]) + 32 <= b.count,
              let length = UInt256(bigEndian: Data(b[Int(offset.words[0]) ..< Int(offset.words[0]) + 32])),
              length.words[1...].allSatisfy({ $0 == 0 }),
              Int(offset.words[0]) + 32 + Int(length.words[0]) <= b.count
        else { throw STSError.invalidField("CONTRACT_SIGNATURE \(owner)") }
        let start = Int(offset.words[0]) + 32
        return Data(b[start ..< start + Int(length.words[0])])
    }

    /// 转成 core 的 SafeTx，用来本地重算 safeTxHash（不信任 STS 返回的哈希）。
    public func safeTx() throws -> SafeTx {
        func address(_ s: String?) throws -> Address {
            guard let s else { return .zero }
            guard let a = Address(hex: s) else { throw STSError.invalidField("address \(s)") }
            return a
        }
        guard let op = SafeTx.Operation(rawValue: UInt8(clamping: operation)) else {
            throw STSError.invalidField("operation \(operation)")
        }
        guard let bytes = Data(hex: data ?? "0x") else { throw STSError.invalidField("data") }
        return SafeTx(
            to: try address(to),
            value: value.value,
            data: bytes,
            operation: op,
            safeTxGas: safeTxGas.value,
            baseGas: baseGas.value,
            gasPrice: gasPrice.value,
            gasToken: try address(gasToken),
            refundReceiver: try address(refundReceiver),
            nonce: nonce.value
        )
    }
}

/// STS 的整数字段：v2 返回十进制字符串，部分 v1 接口返回 JSON 数字，两种都接受。
public struct STSUInt: Decodable, Hashable, Sendable, CustomStringConvertible {
    public let value: UInt256

    public init(_ value: UInt256) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), let v = UInt256(decimal: s) {
            value = v
        } else if let n = try? c.decode(UInt64.self) {
            value = UInt256(n)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是非负整数")
        }
    }

    public var description: String { value.description }
}

/// `POST /api/v2/safes/{address}/multisig-transactions/` 的请求体（STS 的 `SafeMultisigTransaction`）。
struct ProposeBody: Encodable {
    let safe: String
    let to: String
    let value: String
    let data: String?
    let operation: Int
    let gasToken: String
    let safeTxGas: String
    let baseGas: String
    let gasPrice: String
    let refundReceiver: String
    let nonce: String
    let contractTransactionHash: String
    let sender: String
    let signature: String
    let origin: String?
}

/// `POST /api/v1/multisig-transactions/{safe_tx_hash}/confirmations/`
struct ConfirmationBody: Encodable {
    let signature: String
}

public enum STSError: Error, Equatable, Sendable {
    /// 非 2xx。`body` 是 STS 返回的原文，通常是 `{"code":…,"message":…}`。
    case http(status: Int, body: String)
    case invalidResponse
    case invalidField(String)
}
