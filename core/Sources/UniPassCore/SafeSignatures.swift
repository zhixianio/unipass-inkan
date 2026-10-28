import Foundation

/// 一个 owner 对某个 safeTxHash 的签名。
public enum SafeOwnerSignature: Hashable, Sendable {
    /// EOA 的 65 字节 r‖s‖v。
    case eoa(owner: Address, signature: Data)
    /// 合约 owner（EIP-1271），例如 WebAuthn signer proxy；`signature` 是交给合约 `isValidSignature` 的原始字节。
    case contract(owner: Address, signature: Data)

    public var owner: Address {
        switch self {
        case .eoa(let owner, _), .contract(let owner, _): owner
        }
    }
}

public enum SafeSignatures {
    public enum EncodingError: Error, Equatable {
        case invalidEOASignatureLength(Address)
        case duplicateOwner(Address)
    }

    /// 打包成 `execTransaction` 的 `signatures` 参数。
    ///
    /// 静态部分每个 owner 65 字节，按 owner 地址升序。合约签名的静态部分是
    /// `r = owner 地址, s = 动态数据在 signatures 里的偏移, v = 0`，
    /// 动态部分追加在所有静态部分之后：32 字节长度 + 数据。
    public static func encode(_ signatures: [SafeOwnerSignature]) throws -> Data {
        let sorted = signatures.sorted { $0.owner < $1.owner }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.owner == b.owner {
            throw EncodingError.duplicateOwner(a.owner)
        }

        var staticPart = Data()
        var dynamicPart = Data()
        let dynamicStart = sorted.count * 65
        for sig in sorted {
            switch sig {
            case .eoa(let owner, let signature):
                guard signature.count == 65 else { throw EncodingError.invalidEOASignatureLength(owner) }
                staticPart += signature
            case .contract(let owner, let signature):
                staticPart += owner.abiEncoded
                staticPart += UInt256(UInt64(dynamicStart + dynamicPart.count)).bigEndianBytes
                staticPart += Data([0])
                dynamicPart += UInt256(UInt64(signature.count)).bigEndianBytes + signature
            }
        }
        return staticPart + dynamicPart
    }
}
