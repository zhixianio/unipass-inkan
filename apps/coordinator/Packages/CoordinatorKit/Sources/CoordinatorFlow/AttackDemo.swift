#if DEBUG
import Foundation
import UniPassCore

/// 攻击演示（**只在 DEBUG 构建里**，Release 二进制里没有这段代码，见 scripts/check-release-no-attack-demo.sh）：
/// 模拟被篡改的桌面端。界面照样显示用户填的那笔交易，实际发给签名器的请求被换掉，
/// 用来演示签名器自己解码、按规则判定能拦住什么（docs/demo.md）。
///
/// 地址都是演示用的：Bybit 事件公开分析里的两个地址（testvectors/rules/bybit-2025-02-21.json），
/// 地址投毒的仿冒地址直接改中间的十六进制位得到，没有对应的私钥。
public enum AttackDemo: String, CaseIterable, Sendable {
    /// Bybit 式：把"转账"换成对陌生合约的 DELEGATECALL，calldata 伪装成 `transfer`。预期：签名器直接拒签
    /// （DELEGATECALL 到不是 Safe 官方库的合约，`delegateCallNotAllowed`）。
    case bybit
    /// 地址投毒：收款人换成和真收款人首尾相同、中间不同的地址。预期：判红，命中 R05。
    case addressPoisoning
    /// 退款抽干：交易本身不变，gasPrice、baseGas、refundReceiver 改成给攻击者付"退款"。预期：硬拒。
    case refundDrain

    /// Bybit 事件里被 DELEGATECALL 的恶意合约（主网地址；在别的链上只是一个陌生地址）。
    public static let bybitImplementation = Address(hex: "0x96221423681A6d52E184D440a8eFCEbB105C7242")!
    /// Bybit 事件 calldata 里的地址，这里当作攻击者。
    public static let attacker = Address(hex: "0xbDd077f651EBe7f7b3cE16fe5F2b025BE2969516")!

    /// 仿冒地址保留的首尾十六进制位数（真实的地址投毒通常做到 4–6 位；签名器的 R05 只要求首尾各 3 位相同）。
    public static let poisonKeptChars = 6

    /// 被篡改的桌面端实际发给签名器的交易。`shown` 是界面上照样显示的那笔。
    public func tamper(_ shown: SafeTxRequest) -> SafeTxRequest {
        var tx = shown.tx
        switch self {
        case .bybit:
            tx = SafeTx(
                to: Self.bybitImplementation,
                value: .zero,
                data: Self.transferCalldata(to: Self.attacker, amount: .zero),
                operation: .delegateCall,
                nonce: shown.tx.nonce
            )
        case .addressPoisoning:
            if let token = Self.erc20Recipient(shown.tx) {
                tx.data = Self.transferCalldata(to: Self.lookalike(of: token.recipient), amount: token.amount)
            } else {
                tx.to = Self.lookalike(of: shown.tx.to)
            }
        case .refundDrain:
            // 执行时 Safe 额外付 (gasUsed + baseGas) × gasPrice 给 refundReceiver：这里约 1 ETH。
            tx.gasPrice = UInt256(1_000_000_000_000) // 1000 gwei
            tx.baseGas = UInt256(1_000_000)
            tx.refundReceiver = Self.attacker
        }
        return SafeTxRequest(chainID: shown.chainID, safe: shown.safe, tx: tx)
    }

    /// 首尾各 `poisonKeptChars` 位相同、中间每一位都不同的地址。
    public static func lookalike(of a: Address) -> Address {
        let digits = Array("0123456789abcdef")
        let hex = Array(a.bytes.hexString.dropFirst(2))
        var out = hex
        for i in poisonKeptChars ..< hex.count - poisonKeptChars {
            let v = digits.firstIndex(of: hex[i])!
            out[i] = digits[(v + 7) % 16]
        }
        return Address(hex: "0x" + String(out))!
    }

    static func transferCalldata(to: Address, amount: UInt256) -> Data {
        Data(Keccak.hash256(Data("transfer(address,uint256)".utf8)).prefix(4))
            + ABICodec.encode([.address, .uint(256)], [.address(to), .uint(amount)])!
    }

    /// 普通 ERC-20 `transfer` 的收款人和数量；不是的话返回 nil（按原生币转账处理）。
    static func erc20Recipient(_ tx: SafeTx) -> (recipient: Address, amount: UInt256)? {
        guard tx.operation == .call, tx.data.count == 68,
              tx.data.prefix(4) == transferCalldata(to: .zero, amount: .zero).prefix(4),
              let v = ABICodec.decode([.address, .uint(256)], tx.data.dropFirst(4)),
              let to = v[0].address, let amount = v[1].uint
        else { return nil }
        return (to, amount)
    }
}
#endif
