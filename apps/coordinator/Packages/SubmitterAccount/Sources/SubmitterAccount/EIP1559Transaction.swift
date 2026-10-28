import Foundation
import UniPassCore

/// EIP-1559（type 2）交易。access list 一律为空。
public struct EIP1559Transaction: Hashable, Sendable {
    public var chainID: UInt64
    public var nonce: UInt64
    public var maxPriorityFeePerGas: UInt256
    public var maxFeePerGas: UInt256
    public var gasLimit: UInt64
    public var to: Address
    public var value: UInt256
    public var data: Data

    public init(chainID: UInt64, nonce: UInt64, maxPriorityFeePerGas: UInt256, maxFeePerGas: UInt256,
                gasLimit: UInt64, to: Address, value: UInt256 = .zero, data: Data = Data()) {
        self.chainID = chainID
        self.nonce = nonce
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    var fields: [RLP] {
        [.uint(chainID), .uint(nonce), .uint(maxPriorityFeePerGas), .uint(maxFeePerGas), .uint(gasLimit),
         .bytes(to.bytes), .uint(value), .bytes(data), .list([])]
    }

    /// 要签的载荷：`0x02 ‖ rlp([chainId, nonce, …, accessList])`，签的是它的 keccak256。
    public var signingPayload: Data {
        Data([0x02]) + RLP.list(fields).encoded
    }

    /// 广播用的原始交易：`0x02 ‖ rlp([…, yParity, r, s])`。
    public func raw(_ sig: RecoverableSignature) -> Data {
        Data([0x02]) + RLP.list(fields + [
            .uint(UInt64(sig.yParity)),
            .uint(UInt256(bigEndian: sig.r)!),
            .uint(UInt256(bigEndian: sig.s)!),
        ]).encoded
    }

    /// 最多要付的钱：value + gasLimit × maxFeePerGas。超过 256 位时返回 nil。
    public var maxCost: UInt256? {
        guard maxFeePerGas.words[1...].allSatisfy({ $0 == 0 }) else { return nil }
        let (high, low) = gasLimit.multipliedFullWidth(by: maxFeePerGas.words[0])
        return value.adding(UInt256(words: [low, high, 0, 0]))
    }
}

/// secp256k1 可恢复签名（r、s 各 32 字节大端，s 已规范成低半区）。
public struct RecoverableSignature: Hashable, Sendable {
    public var r: Data
    public var s: Data
    public var yParity: UInt8

    public init(r: Data, s: Data, yParity: UInt8) {
        precondition(r.count == 32 && s.count == 32 && yParity <= 1)
        self.r = r
        self.s = s
        self.yParity = yParity
    }
}

extension UInt256 {
    /// 加法，溢出返回 nil。
    func adding(_ rhs: UInt256) -> UInt256? {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (a, o1) = words[i].addingReportingOverflow(rhs.words[i])
            let (b, o2) = a.addingReportingOverflow(carry)
            out[i] = b
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return carry == 0 ? UInt256(words: out) : nil
    }
}
