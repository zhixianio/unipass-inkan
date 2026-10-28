import Foundation
import UniPassCore

/// 桌面端自己的地址簿：只方便输入和显示名字（以签名器上的地址簿为准）。
public struct AddressBook: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var addressHex: String

        public init(name: String, address: Address) {
            self.name = name
            addressHex = address.checksummed
        }

        public var address: Address { Address(hex: addressHex)! }
        public var id: String { addressHex.lowercased() }
    }

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static let maxNameLength = 32

    public func name(for a: Address) -> String? {
        entries.first { $0.address == a }?.name
    }

    /// 新增或改名（同一个地址只留一条）。名字去掉首尾空白，过长截断。
    public mutating func save(name: String, address: Address) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        guard !n.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.address == address }) {
            entries[i].name = n
        } else {
            entries.append(Entry(name: n, address: address))
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func remove(_ address: Address) {
        entries.removeAll { $0.address == address }
    }

    /// 给 core 的规则引擎用（解码时显示名字）。
    public var coreEntries: [AddressBookEntry] {
        entries.map { AddressBookEntry(address: $0.address, label: $0.name) }
    }
}

/// 一笔 Safe 交易在界面上的一句话描述（"发送 25 USDC 给 Alice"）。解码用 core 的规则引擎，句子在 App 里本地化。
public struct TransactionSummary: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// 金额已按代币格式化（例如 "25 USDC"）；收款人名字来自地址簿或"我的 Safe"。
        case send(amount: String, to: Address, toName: String?)
        /// 对合约的调用（包括不认识的代币）。
        case contractCall(target: Address, targetName: String?)
        /// MultiSend 批量。
        case batch(count: Int)
        /// 对 Safe 自己的设置变更（owner、门限……）。
        case settingsChange
        /// 空交易（取消用）。
        case empty
    }

    public var kind: Kind

    public static func describe(_ request: SafeTxRequest, addressBook: AddressBook, labels: LabelLibrary = .builtIn) -> TransactionSummary {
        let ctx = RiskContext(mySafes: [MySafe(chainID: request.chainID, address: request.safe)], addressBook: addressBook.coreEntries,
                              labels: labels)
        let a = RiskEngine(context: ctx).assess(request)
        guard let action = a.actions.first(where: { $0.path.isEmpty }) ?? a.actions.first else {
            if request.tx.data.isEmpty, request.tx.value.isZero { return TransactionSummary(kind: .empty) }
            return TransactionSummary(kind: .contractCall(target: request.tx.to, targetName: addressBook.name(for: request.tx.to)))
        }
        switch action.kind {
        case .nativeTransfer(let to, let amount):
            return TransactionSummary(kind: .send(amount: display(amount), to: to.address, toName: to.label))
        case .tokenTransfer(_, nil, let to, let amount) where action.operation == .call:
            return TransactionSummary(kind: .send(amount: display(amount), to: to.address, toName: to.label))
        case .multiSend(_, let count):
            return TransactionSummary(kind: .batch(count: count))
        case .safeConfig:
            return TransactionSummary(kind: .settingsChange)
        case .emptyCall:
            return TransactionSummary(kind: .empty)
        default:
            return TransactionSummary(kind: .contractCall(target: action.target.address, targetName: action.target.label))
        }
    }

    static func display(_ a: TokenAmount) -> String {
        a.symbol.map { a.formatted + " " + $0 } ?? a.formatted
    }
}

/// 签名人地址不能收款。签名器的 owner 地址是一个签名合约（WebAuthn signer proxy），不是钱包：
/// 往里转的 ERC-20 永远取不出来，在有的链上、或者合约还没部署时，ETH 也一样。
/// 已配对签名器的地址一定算；Safe 的其他签名人在链上有代码（合约）的也算，EOA 签名人照常能收款。
public enum SignerAddresses {
    public static func isSignerContract(_ a: Address, pairedSigners: Set<Address>, safeOwners: Set<Address>, hasCode: Bool) -> Bool {
        pairedSigners.contains(a) || (safeOwners.contains(a) && hasCode)
    }
}
