import Foundation
import UniPassCore

// 发送流程的纯逻辑：资产、金额换算、收款人校验、组 SafeTx。界面在 App 的 SendFlow.swift。

/// 可以发送的资产：链的原生币，或者标签库里这条链的 ERC-20。
public struct Asset: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case native
        case erc20(Address)
    }

    public var kind: Kind
    public var symbol: String
    public var name: String
    public var decimals: Int
    /// nil = 还没读到。
    public var balance: UInt256?

    public init(kind: Kind, symbol: String, name: String, decimals: Int, balance: UInt256? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.balance = balance
    }

    public var id: String {
        switch kind {
        case .native: "native"
        case .erc20(let a): a.checksummed
        }
    }

    public var tokenAddress: Address? {
        if case .erc20(let a) = kind { a } else { nil }
    }

    /// 原生币 + 标签库里这条链的 ERC-20（有 symbol 和 decimals 的）。
    public static func known(chainID: UInt64, labels: LabelLibrary = .builtIn) -> [Asset] {
        let tokens = labels.entries
            .filter { $0.chainId == chainID && $0.kind == .erc20 }
            .compactMap { e -> Asset? in
                guard let a = e.parsedAddress, let symbol = e.symbol, let d = e.decimals else { return nil }
                return Asset(kind: .erc20(a), symbol: symbol, name: cleanName(e.name), decimals: d)
            }
            .sorted { $0.symbol < $1.symbol }
        return [native(chainID: chainID)] + tokens
    }

    public static func native(chainID: UInt64) -> Asset {
        Asset(kind: .native, symbol: "ETH", name: chainID == 11_155_111 ? "Sepolia Ether" : "Ether", decimals: 18)
    }

    /// 标签库的名字带着"(testnet)"之类的注释，界面上去掉。
    static func cleanName(_ s: String) -> String {
        s.replacingOccurrences(of: " (testnet)", with: "")
            .replacingOccurrences(of: " on Ethereum Sepolia Testnet", with: "")
    }

    /// 金额显示，例如 `25 USDC`、`0.001 ETH`（千分位逗号，去掉末尾的 0）。
    public func display(_ raw: UInt256) -> String {
        TokenAmount(raw: raw, decimals: decimals, symbol: symbol).formatted + " " + symbol
    }

    /// 余额显示：最多 `fractionDigits` 位小数，多出来的舍去（不多报）；不是 0 但不到最小一档时显示 `< 0.000001 ETH`。
    /// 完整的值用 `display` 放在悬停提示里。
    public func display(_ raw: UInt256, fractionDigits: Int) -> String {
        let full = TokenAmount(raw: raw, decimals: decimals, symbol: symbol).formatted
        guard let dot = full.firstIndex(of: ".") else { return full + " " + symbol }
        let intPart = full[..<dot]
        let frac = String(full[full.index(after: dot)...].prefix(fractionDigits))
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        if frac.isEmpty, intPart == "0" {
            return "< 0." + String(repeating: "0", count: max(0, fractionDigits - 1)) + "1 " + symbol
        }
        return intPart + (frac.isEmpty ? "" : "." + frac) + " " + symbol
    }
}

/// 用户按代币单位输入的金额（"25"、"0.001"），按 decimals 换算成最小单位。
public enum AmountInput {
    public enum Problem: Error, Hashable, Sendable {
        case empty
        /// 不是"数字 + 可选小数点 + 数字"。
        case invalidFormat
        /// 小数位比代币支持的多。
        case tooManyDecimals(max: Int)
        case zero
        /// 超过 uint256。
        case tooLarge
        case insufficientBalance
    }

    /// 解析，不看余额。接受 `25`、`25.`、`.5`、`0.001`、`1,000.5`（逗号当千分位忽略）。
    public static func parse(_ text: String, decimals: Int) -> Result<UInt256, Problem> {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty else { return .failure(.empty) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.contains(where: { !$0.isEmpty })
        else { return .failure(.invalidFormat) }
        let intPart = String(parts[0])
        let fracPart = parts.count == 2 ? String(parts[1]) : ""
        let trimmedFrac = fracPart.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        guard trimmedFrac.count <= decimals else { return .failure(.tooManyDecimals(max: decimals)) }
        let digits = (intPart.isEmpty ? "0" : intPart) + trimmedFrac + String(repeating: "0", count: decimals - trimmedFrac.count)
        let stripped = String(digits.drop { $0 == "0" })
        guard let value = UInt256(decimal: stripped.isEmpty ? "0" : stripped) else { return .failure(.tooLarge) }
        guard !value.isZero else { return .failure(.zero) }
        return .success(value)
    }

    /// 解析并检查余额（余额未知时不检查）。
    public static func validate(_ text: String, asset: Asset) -> Result<UInt256, Problem> {
        switch parse(text, decimals: asset.decimals) {
        case .failure(let p): return .failure(p)
        case .success(let v):
            if let balance = asset.balance, balance < v { return .failure(.insufficientBalance) }
            return .success(v)
        }
    }

    /// 填进输入框用的写法：不带千分位，去掉末尾的 0（"全部"按钮用）。
    public static func plain(_ raw: UInt256, decimals: Int) -> String {
        TokenAmount(raw: raw, decimals: decimals, symbol: nil).formatted.replacingOccurrences(of: ",", with: "")
    }
}

/// 粘贴的收款地址。
public enum RecipientInput {
    public enum Problem: Error, Hashable, Sendable {
        case empty
        /// 不是 0x + 40 位十六进制。
        case notAnAddress
        /// 大小写混合但 EIP-55 校验和不对：多半是抄错了一位。
        case badChecksum
        case zeroAddress
        /// 收款人就是这个 Safe 自己。
        case isTheSafe
    }

    public static func parse(_ text: String, safe: Address? = nil) -> Result<Address, Problem> {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.empty) }
        let body = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        guard body.count == 40, Data(hex: body) != nil else { return .failure(.notAnAddress) }
        guard let a = Address(hex: "0x" + body) else { return .failure(.badChecksum) }
        if a == .zero { return .failure(.zeroAddress) }
        if let safe, a == safe { return .failure(.isTheSafe) }
        return .success(a)
    }
}

public enum Transfer {
    static let transferSelector = Data(Keccak.hash256(Data("transfer(address,uint256)".utf8)).prefix(4))

    /// 发送一笔资产的 SafeTx：原生币直接转；ERC-20 调 `transfer(to, amount)`。
    public static func safeTx(asset: Asset, to recipient: Address, amount: UInt256, nonce: UInt256) -> SafeTx {
        switch asset.kind {
        case .native:
            SafeTx(to: recipient, value: amount, nonce: nonce)
        case .erc20(let token):
            SafeTx(to: token, data: transferSelector + ABICodec.encode([.address, .uint(256)], [.address(recipient), .uint(amount)])!,
                   nonce: nonce)
        }
    }

    /// `balanceOf(owner)` 的调用数据。
    public static func balanceOfCalldata(_ owner: Address) -> Data {
        Data(Keccak.hash256(Data("balanceOf(address)".utf8)).prefix(4)) + owner.abiEncoded
    }
}

/// 执行一笔 Safe 交易的网络费估算（只用来显示"约多少"，不参与签名）。
public enum FeeEstimate {
    /// 执行大约用多少 gas。实测：Sepolia 测试 Safe（2-of-2，一个 WebAuthn 合约签名 + 一个 EOA 签名）
    /// 执行空调用用了 92,831；转账再加一些余量，ERC-20 的 `transfer` 还要写代币合约的存储。
    public static func executionGas(_ tx: SafeTx) -> UInt64 {
        tx.data.isEmpty ? 110_000 : 140_000
    }

    /// gas × 每 gas 价格（baseFee + 小费）。价格超过 64 位时返回 nil（不会发生在正常网络上）。
    public static func fee(gas: UInt64, baseFee: UInt256, tip: UInt256) -> UInt256? {
        guard baseFee.words[1...].allSatisfy({ $0 == 0 }), tip.words[1...].allSatisfy({ $0 == 0 }) else { return nil }
        let (perGas, overflow) = baseFee.words[0].addingReportingOverflow(tip.words[0])
        guard !overflow else { return nil }
        let (high, low) = gas.multipliedFullWidth(by: perGas)
        return UInt256(words: [low, high, 0, 0])
    }

    /// 显示用的费用：最多 6 位小数、向上取整（宁可多估）；不到最小一档时返回 nil，界面显示"不到 0.000001 ETH"。
    public static func rounded(_ fee: UInt256, asset: Asset) -> UInt256? {
        let keep = 6
        guard asset.decimals > keep, fee.words[1...].allSatisfy({ $0 == 0 }) else { return fee }
        var unit: UInt64 = 1
        for _ in 0 ..< (asset.decimals - keep) {
            let (u, overflow) = unit.multipliedReportingOverflow(by: 10)
            guard !overflow else { return fee }
            unit = u
        }
        let v = fee.words[0]
        guard v >= unit else { return fee.isZero ? fee : nil }
        let (q, r) = v.quotientAndRemainder(dividingBy: unit)
        let (up, overflow) = ((q + (r == 0 ? 0 : 1))).multipliedReportingOverflow(by: unit)
        return overflow ? fee : UInt256(up)
    }

    /// 最小一档（6 位小数），给"不到 …"用。
    public static func smallest(_ asset: Asset) -> String {
        asset.decimals > 6 ? "0.000001 " + asset.symbol : asset.display(UInt256(1))
    }
}

public enum AddressDisplay {
    /// 一行里放不下完整地址时的写法：前 8 位 + 后 8 位（首尾 4+4 防不住地址投毒），例如 `0x938313A5…869AB39a`。
    public static func short(_ a: Address) -> String {
        let s = a.checksummed
        return String(s.prefix(10)) + "…" + String(s.suffix(8))
    }
}
