import Foundation

/// 改 owner / 门限时的前后对比。以"我的 Safe"里记录的 owner 和门限为起点，
/// 按交易里的调用顺序套用变更（和合约行为一致：addOwner 插到最前面，swapOwner 保持位置）。
/// 链上状态可能已经变了，界面要注明"以登记时为准"。
public struct OwnerChangePreview: Hashable, Sendable {
    public enum Warning: Hashable, Sendable {
        /// 门限大于 owner 数：交易会失败。
        case thresholdExceedsOwners
        /// n-of-n：丢掉任何一把钥匙，Safe 就再也动不了。
        case thresholdEqualsOwners
        /// 1-of-n（n > 1）：任何一个 owner 单独就能动资产。
        case singleSignature
        /// 这台 Signer 自己被移除或换掉。
        case removesThisSigner
        /// 要移除 / 替换的 owner 不在记录里（记录过时，或者交易会失败）。
        case ownerNotInRecord(Address)
    }

    public var beforeOwners: [Address]
    public var beforeThreshold: UInt64?
    public var afterOwners: [Address]
    public var afterThreshold: UInt64?
    public var added: [Address]
    public var removed: [Address]
    public var warnings: [Warning]

    /// 没有 owner / 门限变更时返回 nil。
    public init?(_ a: RiskAssessment, safe: MySafe, thisSigner: Address? = nil) {
        let changes = a.actions.compactMap { action -> SafeConfigChange? in
            guard action.target.address == safe.address, case .safeConfig(let c) = action.kind else { return nil }
            switch c {
            case .addOwner, .removeOwner, .swapOwner, .changeThreshold: return c
            default: return nil
            }
        }
        guard !changes.isEmpty else { return nil }
        var owners = safe.owners
        var threshold = safe.threshold
        var warnings: [Warning] = []
        func clamp(_ t: UInt256) -> UInt64 { t.words[1...].allSatisfy { $0 == 0 } ? t.words[0] : .max }
        for c in changes {
            switch c {
            case .addOwner(let o, let t):
                owners.insert(o.address, at: 0)
                threshold = clamp(t)
            case .removeOwner(let o, let t):
                if let i = owners.firstIndex(of: o.address) { owners.remove(at: i) } else { warnings.append(.ownerNotInRecord(o.address)) }
                threshold = clamp(t)
            case .swapOwner(let old, let new):
                if let i = owners.firstIndex(of: old.address) { owners[i] = new.address } else { warnings.append(.ownerNotInRecord(old.address)) }
            case .changeThreshold(let t):
                threshold = clamp(t)
            default: break
            }
        }
        if let t = threshold {
            if t > UInt64(owners.count) { warnings.append(.thresholdExceedsOwners) }
            else if t == UInt64(owners.count), owners.count > 1 { warnings.append(.thresholdEqualsOwners) }
            else if t == 1, owners.count > 1 { warnings.append(.singleSignature) }
        }
        if let me = thisSigner, safe.owners.contains(me), !owners.contains(me) { warnings.append(.removesThisSigner) }
        beforeOwners = safe.owners
        beforeThreshold = safe.threshold
        afterOwners = owners
        afterThreshold = threshold
        added = owners.filter { !safe.owners.contains($0) }
        removed = safe.owners.filter { !owners.contains($0) }
        self.warnings = warnings
    }
}
