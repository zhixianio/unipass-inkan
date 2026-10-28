import Foundation
import UniPassCore

/// `Safe.execTransaction` 的调用数据。由提交账户（或用户在 Safe{Wallet} 里用自己的钱包）发出。
public enum ExecTransaction {
    static let selector = Data(Keccak.hash256(Data(
        "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)".utf8
    )).prefix(4))

    public static func calldata(_ tx: SafeTx, signatures: Data) -> Data {
        let args = ABICodec.encode(
            [.address, .uint(256), .bytes, .uint(8), .uint(256), .uint(256), .uint(256), .address, .address, .bytes],
            [.address(tx.to), .uint(tx.value), .bytes(tx.data), .uint(UInt256(UInt64(tx.operation.rawValue))),
             .uint(tx.safeTxGas), .uint(tx.baseGas), .uint(tx.gasPrice), .address(tx.gasToken), .address(tx.refundReceiver),
             .bytes(signatures)]
        )!
        return selector + args
    }

    /// 执行前的链上预检：`checkSignatures(bytes32 dataHash, bytes data, bytes signatures)`（Safe 1.3.0 – 1.4.1），
    /// 用 eth_call 调，不消耗 nonce。`data` 是 EIP-712 编码前的 `0x19 ‖ 0x01 ‖ domainSeparator ‖ structHash`。
    public static func checkSignaturesCalldata(_ request: SafeTxRequest, signatures: Data) -> Data {
        let domain = SafeDomain(chainId: UInt256(request.chainID), safe: request.safe)
        let encoded = Data([0x19, 0x01]) + domain.separator + request.tx.structHash
        let args = ABICodec.encode(
            [.uint(256), .bytes, .bytes],
            [.uint(UInt256(bigEndian: request.safeTxHash)!), .bytes(encoded), .bytes(signatures)]
        )!
        return Data(Keccak.hash256(Data("checkSignatures(bytes32,bytes,bytes)".utf8)).prefix(4)) + args
    }

    /// 用 Foundry keystore 账户发出这笔交易的命令（测试网一次性账户用；外部钱包只要发同样的 to + calldata）。
    public static func castCommand(safe: Address, tx: SafeTx, signatures: Data, rpcURL: String, account: String) -> String {
        "cast send --rpc-url \(rpcURL) --account \(account) \(safe.checksummed) \(calldata(tx, signatures: signatures).hexString)"
    }
}
