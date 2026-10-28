import Foundation

/// Safe（≥1.3.0）的一笔交易，字段与合约里的 SafeTx 类型一一对应。
public struct SafeTx: Hashable, Sendable {
    public enum Operation: UInt8, Sendable {
        case call = 0
        case delegateCall = 1
    }

    public var to: Address
    public var value: UInt256
    public var data: Data
    public var operation: Operation
    public var safeTxGas: UInt256
    public var baseGas: UInt256
    public var gasPrice: UInt256
    public var gasToken: Address
    public var refundReceiver: Address
    public var nonce: UInt256

    public init(
        to: Address,
        value: UInt256 = .zero,
        data: Data = Data(),
        operation: Operation = .call,
        safeTxGas: UInt256 = .zero,
        baseGas: UInt256 = .zero,
        gasPrice: UInt256 = .zero,
        gasToken: Address = .zero,
        refundReceiver: Address = .zero,
        nonce: UInt256
    ) {
        self.to = to
        self.value = value
        self.data = data
        self.operation = operation
        self.safeTxGas = safeTxGas
        self.baseGas = baseGas
        self.gasPrice = gasPrice
        self.gasToken = gasToken
        self.refundReceiver = refundReceiver
        self.nonce = nonce
    }

    static let typeHash = Keccak.hash256(Data(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)".utf8
    ))

    /// EIP-712 hashStruct(SafeTx)。
    public var structHash: Data {
        var enc = Self.typeHash
        enc += to.abiEncoded
        enc += value.bigEndianBytes
        enc += Keccak.hash256(data)
        enc += UInt256(UInt64(operation.rawValue)).bigEndianBytes
        enc += safeTxGas.bigEndianBytes
        enc += baseGas.bigEndianBytes
        enc += gasPrice.bigEndianBytes
        enc += gasToken.abiEncoded
        enc += refundReceiver.abiEncoded
        enc += nonce.bigEndianBytes
        return Keccak.hash256(enc)
    }

    /// safeTxHash：owner 实际签名的 32 字节。
    public func hash(chainId: UInt256, safe: Address) -> Data {
        SafeDomain(chainId: chainId, safe: safe).typedDataHash(structHash: structHash)
    }
}

/// Safe ≥1.3.0 的 EIP-712 domain：只有 chainId 和 verifyingContract。
public struct SafeDomain: Hashable, Sendable {
    public var chainId: UInt256
    public var safe: Address

    public init(chainId: UInt256, safe: Address) {
        self.chainId = chainId
        self.safe = safe
    }

    static let typeHash = Keccak.hash256(Data("EIP712Domain(uint256 chainId,address verifyingContract)".utf8))

    public var separator: Data {
        Keccak.hash256(Self.typeHash + chainId.bigEndianBytes + safe.abiEncoded)
    }

    public func typedDataHash(structHash: Data) -> Data {
        Keccak.hash256(Data([0x19, 0x01]) + separator + structHash)
    }
}
