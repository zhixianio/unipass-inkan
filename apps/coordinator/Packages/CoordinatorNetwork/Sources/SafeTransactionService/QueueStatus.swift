import Foundation
import UniPassCore

/// 一笔 Safe 交易在界面上的状态（"待签 1/2""可执行""已上链"）。
public enum QueueStatus: Hashable, Sendable {
    case awaitingSignatures(collected: Int, required: Int)
    /// 签满了，等人执行。
    case ready
    case executed(succeeded: Bool)
    /// 链上的编号已经过了这一笔，签满了，但交易服务还没记上执行结果：多半就是这一笔刚上链，服务晚几秒才同步。
    case confirming
    /// "正在确认"太久还没同步过来：可能被另一笔交易用掉了编号，而那笔不在交易服务返回的最近记录里。
    case unconfirmed
    /// 同一个编号已经被别的交易用掉了，这笔再也不能执行。
    case replaced
}

extension QueueStatus {
    /// 显示"正在确认"超过 `timeout` 秒还没变，就改成"状态还没确认"。`since` 是第一次显示"正在确认"的时间。
    public func timingOut(since: Date?, now: Date, timeout: TimeInterval = 120) -> QueueStatus {
        guard self == .confirming, let since, now.timeIntervalSince(since) >= timeout else { return self }
        return .unconfirmed
    }
}

extension MultisigTransaction {
    /// `safeNonce` 是链上 Safe 当前的 nonce；不知道时传 nil（不判断是否被替换）。`siblings` 是交易服务里同一个 Safe 的其他记录。
    ///
    /// 链上的 nonce 比交易服务先更新：一笔刚执行的交易会有几秒"编号已过、但没标成已执行"。所以只有同编号的另一笔已执行，
    /// 或者这笔根本没签满（不可能是它执行的），才算被替换；签满的先显示"正在确认"。
    public func status(safeNonce: UInt256?, siblings: [MultisigTransaction] = []) -> QueueStatus {
        if isExecuted { return .executed(succeeded: isSuccessful ?? true) }
        let collected = confirmations?.count ?? 0
        let signed = collected >= confirmationsRequired
        if let safeNonce, nonce.value < safeNonce {
            let otherExecuted = siblings.contains { $0.nonce.value == nonce.value && $0.safeTxHash != safeTxHash && $0.isExecuted }
            return signed && !otherExecuted ? .confirming : .replaced
        }
        return signed ? .ready : .awaitingSignatures(collected: collected, required: confirmationsRequired)
    }

    /// 上链时间，没上链用提交时间。
    public var date: Date? {
        (executionDate ?? submissionDate).flatMap(Self.parseDate)
    }

    public func hasConfirmation(from owner: Address) -> Bool {
        (confirmations ?? []).contains { Address(hex: $0.owner.lowercased()) == owner }
    }

    /// STS 的时间有的带小数秒（`2026-10-26T00:31:20.681723Z`），有的不带。
    static func parseDate(_ s: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? withFraction.parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}

extension MultisigTransaction {
    /// 进度：上链的最靠后，其次看签名数。同一笔交易的两份记录比这个，留进度靠后的那份。
    var progress: Int { isExecuted ? Int.max : confirmations?.count ?? 0 }

    /// 用交易服务的列表替换本地记录，但本地已经知道更新状态的（单笔查询、刚提交的签名）不被列表里的旧数据盖掉：
    /// 列表有时比单笔查询晚几秒。
    public static func merge(fetched: [MultisigTransaction], known: [MultisigTransaction]) -> [MultisigTransaction] {
        fetched.map { f in
            guard let k = known.first(where: { $0.safeTxHash == f.safeTxHash }), k.progress > f.progress else { return f }
            return k
        }
    }
}
