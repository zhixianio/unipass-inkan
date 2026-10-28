import Foundation

/// 识别出的函数调用。参数都已按标准 ABI 编码校验过。
public enum KnownCall: Hashable, Sendable {
    // ERC-20
    case erc20Transfer(to: Address, amount: UInt256)
    /// `transferFrom(address,address,uint256)`：ERC-20 和 ERC-721 用同一个选择器，第三个参数是数量或 tokenId，
    /// 光看调用数据分不清，由规则 / 标签库判断。
    case transferFrom(from: Address, to: Address, amountOrTokenID: UInt256)
    case erc20Approve(spender: Address, amount: UInt256)
    case increaseAllowance(spender: Address, addedValue: UInt256)
    case decreaseAllowance(spender: Address, subtractedValue: UInt256)
    // ERC-721 / ERC-1155
    case setApprovalForAll(operator: Address, approved: Bool)
    /// ERC-721 `safeTransferFrom`，带或不带 data。
    case erc721SafeTransferFrom(from: Address, to: Address, tokenID: UInt256, data: Data?)
    case erc1155SafeTransferFrom(from: Address, to: Address, id: UInt256, amount: UInt256, data: Data)
    case erc1155SafeBatchTransferFrom(from: Address, to: Address, ids: [UInt256], amounts: [UInt256], data: Data)
    // 代币的"别名函数"（安全核查 P1-1）：transferAndCall / approveAndCall / increaseApproval / authorizeOperator / DAI push、move
    // 直接映射到上面的标准动作；这两个没有对应的标准动作：
    /// DAI `pull(usr, wad)`：从 usr 拉到调用者（这个 Safe）。
    case erc20Pull(from: Address, amount: UInt256)
    /// stETH `transferShares` / `transferSharesFrom`：数量是份额，不是代币数量。
    case transferShares(from: Address?, to: Address, shares: UInt256)
    // Permit2（只在规范 Permit2 地址上识别）
    case permit2Approve(token: Address, spender: Address, amount: UInt256, expiration: UInt64)
    // Safe 自身（只在 to == 这个 Safe 时识别）
    case addOwnerWithThreshold(owner: Address, threshold: UInt256)
    case removeOwner(prevOwner: Address, owner: Address, threshold: UInt256)
    case swapOwner(prevOwner: Address, oldOwner: Address, newOwner: Address)
    case changeThreshold(UInt256)
    case enableModule(Address)
    case disableModule(prevModule: Address, module: Address)
    case setGuard(Address)
    /// Safe 1.5.0 起才有。
    case setModuleGuard(Address)
    case setFallbackHandler(Address)
}

public enum MultiSendKind: Hashable, Sendable {
    case multiSend
    /// 内部只允许 CALL。
    case callOnly
}

/// Safe 官方部署的 MultiSend / MultiSendCallOnly（safe-deployments，见 `SafeDeployments`）。
public struct MultiSendContract: Hashable, Sendable {
    public let kind: MultiSendKind
    public let version: String
    public let address: Address

    /// 1.5.0 起，内部交易的 `to` 为零地址时改成 Safe 自己（`to := or(to, mul(iszero(to), address()))`）。
    public var zeroAddressMeansSelf: Bool { version == "1.5.0" }
}

/// 不能执行或者编码不规范的地方。规则层把它们一律判为硬拒。
public enum DecodingProblem: Hashable, Sendable {
    /// 选择器认识，但参数不是标准 ABI 编码（或宽度越界）。
    case malformedArguments(String)
    /// MultiSend 的打包数据截断、长度不符或有多余字节。
    case malformedMultiSend
    /// 用 CALL 调 MultiSend（会 revert）或 MultiSendCallOnly（内部调用的 msg.sender 不是 Safe）。
    case multiSendViaCall
    /// 内部交易的 operation 不是 0/1（合约里会 revert）。
    case invalidInnerOperation(UInt8)
    /// MultiSendCallOnly 里出现 DELEGATECALL（合约里会 revert）。
    case delegateCallInCallOnly
    case nestingTooDeep
    case tooManyCalls
}

/// 一个调用（顶层 SafeTx 或 MultiSend 里的一条）。
public indirect enum CallAction: Hashable, Sendable {
    /// 没有调用数据：单纯转原生币（或者对合约的空调用）。
    case plain
    case known(KnownCall)
    case multiSend(MultiSendContract, [DecodedCall])
    /// 不认识的函数；调用数据不足 4 字节时 selector 为 nil。
    case unknown(selector: Data?)
    case invalid(DecodingProblem)
}

public struct DecodedCall: Hashable, Sendable {
    public var operation: SafeTx.Operation
    /// 实际被调用的地址（已经按 MultiSend 1.5.0 的规则把零地址换成 Safe）。
    public var to: Address
    /// 原始数据里的 `to`（只有在被替换时和 `to` 不同）。
    public var rawTo: Address
    public var value: UInt256
    public var data: Data
    public var action: CallAction

    /// 自己以及所有内部调用（深度优先）。
    public var flattened: [DecodedCall] {
        if case .multiSend(_, let inner) = action { return [self] + inner.flatMap(\.flattened) }
        return [self]
    }

    /// 自己或任何内部调用里有不能执行 / 编码不规范的地方。
    public var problems: [DecodingProblem] {
        flattened.compactMap { if case .invalid(let p) = $0.action { p } else { nil } }
    }
}

public struct DecodedSafeTx: Hashable, Sendable {
    public var request: SafeTxRequest
    public var call: DecodedCall

    public init(_ request: SafeTxRequest, limits: CallDecoder.Limits = .init()) {
        self.request = request
        call = CallDecoder(chainID: request.chainID, safe: request.safe, limits: limits).decode(
            operation: request.tx.operation, to: request.tx.to, value: request.tx.value, data: request.tx.data)
    }
}

public struct CallDecoder: Sendable {
    public struct Limits: Sendable {
        /// MultiSend 嵌套层数（顶层的 MultiSend 算 1）。
        public var maxDepth = 3
        /// 展开后的调用总数。
        public var maxCalls = 128
        public init() {}
    }

    public let chainID: UInt64
    public let safe: Address
    public let limits: Limits

    public init(chainID: UInt64, safe: Address, limits: Limits = .init()) {
        self.chainID = chainID
        self.safe = safe
        self.limits = limits
    }

    public func decode(operation: SafeTx.Operation, to: Address, value: UInt256, data: Data) -> DecodedCall {
        var budget = limits.maxCalls
        return decode(operation: operation, to: to, rawTo: to, value: value, data: data, depth: 0, budget: &budget)
    }

    private func decode(operation: SafeTx.Operation, to: Address, rawTo: Address, value: UInt256, data: Data,
                        depth: Int, budget: inout Int) -> DecodedCall {
        var call = DecodedCall(operation: operation, to: to, rawTo: rawTo, value: value, data: data, action: .plain)
        guard !data.isEmpty else { return call }
        guard data.count >= 4 else {
            call.action = .unknown(selector: nil)
            return call
        }
        let selector = Data(data.prefix(4))
        let args = Data(data.dropFirst(4))

        if let ms = SafeDeployments.multiSend(chainID: chainID, address: to), selector == Selectors.multiSend {
            call.action = decodeMultiSend(ms, operation: operation, args: args, depth: depth, budget: &budget)
            return call
        }
        call.action = Self.decodeKnown(selector: selector, args: args, to: to, safe: safe)
        return call
    }

    private func decodeMultiSend(_ ms: MultiSendContract, operation: SafeTx.Operation, args: Data, depth: Int,
                                 budget: inout Int) -> CallAction {
        guard operation == .delegateCall else { return .invalid(.multiSendViaCall) }
        guard depth + 1 <= limits.maxDepth else { return .invalid(.nestingTooDeep) }
        guard let packed = ABICodec.decode([.bytes], args)?.first?.bytes else {
            return .invalid(.malformedArguments("multiSend"))
        }
        // 打包格式：operation(1) ‖ to(20) ‖ value(32) ‖ dataLength(32) ‖ data，必须正好用完。
        let b = [UInt8](packed)
        var i = 0
        var calls: [DecodedCall] = []
        while i < b.count {
            guard b.count - i >= 85 else { return .invalid(.malformedMultiSend) }
            let op = b[i]
            let rawTo = Address(bytes: Data(b[i + 1..<i + 21]))!
            let value = UInt256(bigEndian: Data(b[i + 21..<i + 53]))!
            let lenWord = b[i + 53..<i + 85]
            guard lenWord.prefix(28).allSatisfy({ $0 == 0 }) else { return .invalid(.malformedMultiSend) }
            let len = lenWord.suffix(4).reduce(0) { $0 << 8 | Int($1) }
            guard len <= b.count - i - 85 else { return .invalid(.malformedMultiSend) }
            let data = Data(b[i + 85..<i + 85 + len])
            i += 85 + len

            budget -= 1
            guard budget >= 0 else { return .invalid(.tooManyCalls) }
            guard let operation = SafeTx.Operation(rawValue: op) else { return .invalid(.invalidInnerOperation(op)) }
            if ms.kind == .callOnly, operation == .delegateCall { return .invalid(.delegateCallInCallOnly) }
            let to = ms.zeroAddressMeansSelf && rawTo == .zero ? safe : rawTo
            calls.append(decode(operation: operation, to: to, rawTo: rawTo, value: value, data: data,
                                depth: depth + 1, budget: &budget))
        }
        return .multiSend(ms, calls)
    }

    static func decodeKnown(selector: Data, args: Data, to: Address, safe: Address) -> CallAction {
        guard let fn = Selectors.byID[selector] else { return .unknown(selector: selector) }
        switch fn.scope {
        case .anyContract: break
        case .permit2: guard to == SafeDeployments.permit2 else { return .unknown(selector: selector) }
        case .safeSelf: guard to == safe else { return .unknown(selector: selector) }
        }
        guard let v = ABICodec.decode(fn.types, args) else { return .invalid(.malformedArguments(fn.signature)) }
        return .known(fn.build(v))
    }
}

/// 函数签名表。选择器从签名字符串用 keccak256 算出来，不手写。
enum Selectors {
    enum Scope { case anyContract, permit2, safeSelf }

    struct Function: @unchecked Sendable {
        let signature: String
        let types: [ABIType]
        let scope: Scope
        let build: ([ABIValue]) -> KnownCall
        var selector: Data { Data(Keccak.hash256(Data(signature.utf8)).prefix(4)) }
    }

    static let multiSend = Data(Keccak.hash256(Data("multiSend(bytes)".utf8)).prefix(4))

    static let functions: [Function] = [
        Function(signature: "transfer(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .erc20Transfer(to: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "transferFrom(address,address,uint256)", types: [.address, .address, .uint(256)], scope: .anyContract) {
            .transferFrom(from: $0[0].address!, to: $0[1].address!, amountOrTokenID: $0[2].uint!) },
        Function(signature: "approve(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .erc20Approve(spender: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "increaseAllowance(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .increaseAllowance(spender: $0[0].address!, addedValue: $0[1].uint!) },
        Function(signature: "decreaseAllowance(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .decreaseAllowance(spender: $0[0].address!, subtractedValue: $0[1].uint!) },
        Function(signature: "setApprovalForAll(address,bool)", types: [.address, .bool], scope: .anyContract) {
            .setApprovalForAll(operator: $0[0].address!, approved: $0[1].bool!) },
        Function(signature: "safeTransferFrom(address,address,uint256)", types: [.address, .address, .uint(256)], scope: .anyContract) {
            .erc721SafeTransferFrom(from: $0[0].address!, to: $0[1].address!, tokenID: $0[2].uint!, data: nil) },
        Function(signature: "safeTransferFrom(address,address,uint256,bytes)", types: [.address, .address, .uint(256), .bytes], scope: .anyContract) {
            .erc721SafeTransferFrom(from: $0[0].address!, to: $0[1].address!, tokenID: $0[2].uint!, data: $0[3].bytes!) },
        Function(signature: "safeTransferFrom(address,address,uint256,uint256,bytes)",
                 types: [.address, .address, .uint(256), .uint(256), .bytes], scope: .anyContract) {
            .erc1155SafeTransferFrom(from: $0[0].address!, to: $0[1].address!, id: $0[2].uint!, amount: $0[3].uint!, data: $0[4].bytes!) },
        Function(signature: "safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)",
                 types: [.address, .address, .uintArray, .uintArray, .bytes], scope: .anyContract) {
            .erc1155SafeBatchTransferFrom(from: $0[0].address!, to: $0[1].address!, ids: $0[2].uints!, amounts: $0[3].uints!, data: $0[4].bytes!) },
        // 别名函数：和标准函数做同样的事，必须走同样的规则。
        Function(signature: "increaseApproval(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .increaseAllowance(spender: $0[0].address!, addedValue: $0[1].uint!) },
        Function(signature: "decreaseApproval(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .decreaseAllowance(spender: $0[0].address!, subtractedValue: $0[1].uint!) },
        Function(signature: "transferAndCall(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .erc20Transfer(to: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "transferAndCall(address,uint256,bytes)", types: [.address, .uint(256), .bytes], scope: .anyContract) {
            .erc20Transfer(to: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "approveAndCall(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .erc20Approve(spender: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "approveAndCall(address,uint256,bytes)", types: [.address, .uint(256), .bytes], scope: .anyContract) {
            .erc20Approve(spender: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "push(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .erc20Transfer(to: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "move(address,address,uint256)", types: [.address, .address, .uint(256)], scope: .anyContract) {
            .transferFrom(from: $0[0].address!, to: $0[1].address!, amountOrTokenID: $0[2].uint!) },
        Function(signature: "pull(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .erc20Pull(from: $0[0].address!, amount: $0[1].uint!) },
        Function(signature: "authorizeOperator(address)", types: [.address], scope: .anyContract) {
            .setApprovalForAll(operator: $0[0].address!, approved: true) },
        Function(signature: "revokeOperator(address)", types: [.address], scope: .anyContract) {
            .setApprovalForAll(operator: $0[0].address!, approved: false) },
        Function(signature: "transferShares(address,uint256)", types: [.address, .uint(256)], scope: .anyContract) {
            .transferShares(from: nil, to: $0[0].address!, shares: $0[1].uint!) },
        Function(signature: "transferSharesFrom(address,address,uint256)", types: [.address, .address, .uint(256)], scope: .anyContract) {
            .transferShares(from: $0[0].address!, to: $0[1].address!, shares: $0[2].uint!) },
        Function(signature: "approve(address,address,uint160,uint48)", types: [.address, .address, .uint(160), .uint(48)], scope: .permit2) {
            .permit2Approve(token: $0[0].address!, spender: $0[1].address!, amount: $0[2].uint!,
                            expiration: UInt64($0[3].uint!.words[0])) },
        Function(signature: "addOwnerWithThreshold(address,uint256)", types: [.address, .uint(256)], scope: .safeSelf) {
            .addOwnerWithThreshold(owner: $0[0].address!, threshold: $0[1].uint!) },
        Function(signature: "removeOwner(address,address,uint256)", types: [.address, .address, .uint(256)], scope: .safeSelf) {
            .removeOwner(prevOwner: $0[0].address!, owner: $0[1].address!, threshold: $0[2].uint!) },
        Function(signature: "swapOwner(address,address,address)", types: [.address, .address, .address], scope: .safeSelf) {
            .swapOwner(prevOwner: $0[0].address!, oldOwner: $0[1].address!, newOwner: $0[2].address!) },
        Function(signature: "changeThreshold(uint256)", types: [.uint(256)], scope: .safeSelf) {
            .changeThreshold($0[0].uint!) },
        Function(signature: "enableModule(address)", types: [.address], scope: .safeSelf) { .enableModule($0[0].address!) },
        Function(signature: "disableModule(address,address)", types: [.address, .address], scope: .safeSelf) {
            .disableModule(prevModule: $0[0].address!, module: $0[1].address!) },
        Function(signature: "setGuard(address)", types: [.address], scope: .safeSelf) { .setGuard($0[0].address!) },
        Function(signature: "setModuleGuard(address)", types: [.address], scope: .safeSelf) { .setModuleGuard($0[0].address!) },
        Function(signature: "setFallbackHandler(address)", types: [.address], scope: .safeSelf) { .setFallbackHandler($0[0].address!) },
    ]

    static let byID: [Data: Function] = Dictionary(uniqueKeysWithValues: functions.map { ($0.selector, $0) })

    /// Safe 自己的 owner / 模块 / 设置管理和执行类函数（1.3.0–1.5.0）。对 Safe 自己以外的地址调用它们时不解码，
    /// 规则层按 R02 判红：目标可能是另一个 Safe（嵌套 Safe），这些调用能改它的签名人、替它批准或执行交易。
    static let safeManagement: Set<Data> = Set([
        "addOwnerWithThreshold(address,uint256)", "removeOwner(address,address,uint256)", "swapOwner(address,address,address)",
        "changeThreshold(uint256)", "enableModule(address)", "disableModule(address,address)", "setGuard(address)",
        "setModuleGuard(address)", "setFallbackHandler(address)", "approveHash(bytes32)",
        "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
        "execTransactionFromModule(address,uint256,bytes,uint8)", "execTransactionFromModuleReturnData(address,uint256,bytes,uint8)",
        "setup(address[],uint256,address,bytes,address,address,uint256,address)",
    ].map { Data(Keccak.hash256(Data($0.utf8)).prefix(4)) })
}

/// Safe 官方部署地址，来源：github.com/safe-global/safe-deployments（MIT）
/// commit 8e200b0b4c72dbbfe371cbd61b3a21ae2ec4af62，`src/assets/v*/multi_send*.json` 的 networkAddresses。
public enum SafeDeployments {
    /// 首发链 + 开发链。
    public static let supportedChains: Set<UInt64> = [1, 8453, 11_155_111]

    /// Permit2 在所有链上的地址相同（Uniswap 用 CREATE2 部署）。来源：github.com/Uniswap/permit2（MIT）
    /// `test/utils/DeployPermit2.sol` 的 `PERMIT2_ADDRESS`；`approve` 的签名见 `src/AllowanceTransfer.sol`。
    public static let permit2 = Address(hex: "0x000000000022D473030F116dDEE9F6B43aC78BA3")!

    /// safe-modules 的 SafeWebAuthnSignerFactory（4337 v0.2.1，各链地址相同），签名器的 signer proxy 由它创建。
    public static let webAuthnSignerFactory = Address(hex: "0x1d31F259eE307358a26dFb23EB365939E8641195")!

    static func contract(_ kind: MultiSendKind, _ version: String, _ hex: String) -> MultiSendContract {
        MultiSendContract(kind: kind, version: version, address: Address(hex: hex)!)
    }

    /// 三条链上 networkAddresses 相同：1.3.0 有 canonical 和 eip155 两份，1.4.1 / 1.5.0 只有 canonical。
    public static let multiSendContracts: [MultiSendContract] = [
        contract(.multiSend, "1.3.0", "0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761"),
        contract(.multiSend, "1.3.0", "0x998739BFdAAdde7C933B942a68053933098f9EDa"),
        contract(.callOnly, "1.3.0", "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"),
        contract(.callOnly, "1.3.0", "0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B"),
        contract(.multiSend, "1.4.1", "0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"),
        contract(.callOnly, "1.4.1", "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"),
        contract(.multiSend, "1.5.0", "0x218543288004CD07832472D464648173c77D7eB7"),
        contract(.callOnly, "1.5.0", "0xA83c336B20401Af773B6219BA5027174338D1836"),
    ]

    /// MultiSend 以外仍可 DELEGATECALL 的 Safe 官方库（R01 红，可输入确认字符越过）：升级 Safe 版本（SafeMigration、
    /// SafeToL2Migration）和从 Safe 部署合约（CreateCall）。少见，但可能由其他签名人在 Safe{Wallet} 里发起。
    /// 其余官方库在 SafeTx 里没有正当用途，和任何别的合约一样硬拒：SignMessageLib 让 Safe 认可一个签名器解读不了的
    /// 消息哈希（等于盲签），SafeToL2Setup 只在创建 Safe 时用，SimulateTxAccessor 只用于模拟。地址同标签库。
    public static let delegateCallLibraries: Set<Address> = Set([
        "0x526643F69b81B008F46d95CD5ced5eC0edFFDaC6",  // SafeMigration 1.4.1
        "0x6439e7ABD8Bb915A5263094784C5CF561c4172AC",  // SafeMigration 1.5.0
        "0xfF83F6335d8930cBad1c0D439A841f01888D9f69",  // SafeToL2Migration 1.4.1
        "0x7cbB62EaA69F79e6873cD1ecB2392971036cFAa4",  // CreateCall 1.3.0
        "0xB19D6FFc2182150F8Eb585b79D4ABcd7C5640A9d",  // CreateCall 1.3.0 (eip155)
        "0x9b35Af71d77eaf8d7e40252370304687390A1A52",  // CreateCall 1.4.1
        "0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4",  // CreateCall 1.5.0
    ].map { Address(hex: $0)! })

    public static func multiSend(chainID: UInt64, address: Address) -> MultiSendContract? {
        guard supportedChains.contains(chainID) else { return nil }
        return multiSendContracts.first { $0.address == address }
    }
}
