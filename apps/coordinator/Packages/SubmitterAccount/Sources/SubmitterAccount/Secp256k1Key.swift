import Foundation
import libsecp256k1
import Security
import UniPassCore

/// 提交账户的私钥。这个包里只有这个文件用到 libsecp256k1（直接调 C 接口）。
public struct Secp256k1Key: Sendable {
    /// 32 字节私钥。
    let rawRepresentation: Data

    /// 不在 [1, n-1] 范围内时抛错。
    public init(_ raw: Data) throws {
        guard raw.count == 32, raw.withUnsafeBytes({ secp256k1_ec_seckey_verify(Self.context, $0.baseAddress!) }) == 1 else {
            throw KeyError.invalidKey
        }
        rawRepresentation = raw
    }

    /// 用系统的安全随机数生成新私钥。
    public static func generate() throws -> Secp256k1Key {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KeyError.randomFailed }
        return try Secp256k1Key(Data(bytes))
    }

    enum KeyError: Error { case invalidKey, randomFailed, signingFailed }

    /// 签名用的上下文：创建后随机化一次（libsecp256k1 推荐的侧信道防护），之后只读，可以跨线程共用。
    nonisolated(unsafe) static let context: OpaquePointer = {
        let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE))!
        var seed = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess {
            _ = secp256k1_context_randomize(ctx, seed)
        }
        return ctx
    }()

    /// 地址：`keccak256(公钥 x ‖ y)` 的后 20 字节。
    public var address: Address {
        var pubkey = secp256k1_pubkey()
        var out = [UInt8](repeating: 0, count: 65)
        var length = out.count
        let ok = rawRepresentation.withUnsafeBytes { key in
            secp256k1_ec_pubkey_create(Self.context, &pubkey, key.baseAddress!) == 1
                && secp256k1_ec_pubkey_serialize(Self.context, &out, &length, &pubkey, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1
        }
        precondition(ok && length == 65, "init 已核对过私钥") // 65 字节：0x04 ‖ x ‖ y
        return Address(bytes: Keccak.hash256(Data(out.dropFirst())).suffix(20))!
    }

    /// 签 EIP-1559 交易的载荷（RFC 6979 确定性 nonce，libsecp256k1 只产生低半区的 s）。不提供"签任意哈希"：
    /// 载荷不是 type 2 的（包括 type-4 交易和 EIP-7702 授权）在算哈希之前就拒绝（`SigningPolicy.swift`）。
    func sign(payload: Data) throws -> RecoverableSignature {
        try SigningPayload.validate(payload)
        let hash = [UInt8](Keccak.hash256(payload))
        var sig = secp256k1_ecdsa_recoverable_signature()
        var compact = [UInt8](repeating: 0, count: 64)
        var recid: Int32 = 0
        let ok = rawRepresentation.withUnsafeBytes { key in
            secp256k1_ecdsa_sign_recoverable(Self.context, &sig, hash, key.baseAddress!, nil, nil) == 1
                && secp256k1_ecdsa_recoverable_signature_serialize_compact(Self.context, &compact, &recid, &sig) == 1
        }
        guard ok, (0...1).contains(recid) else { throw KeyError.signingFailed }
        return RecoverableSignature(r: Data(compact[0..<32]), s: Data(compact[32..<64]), yParity: UInt8(recid))
    }
}
