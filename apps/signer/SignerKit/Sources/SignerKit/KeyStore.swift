import CryptoKit
import Foundation
import Security

/// 把 owner 密钥存进 Keychain（generic password）。
///
/// 存的内容：1 字节 `SigningKeyKind` + 密钥数据。SE 密钥存 `dataRepresentation`
/// （SE 加密过的句柄，离开这台设备没用）；软件后备存私钥原文。
/// SE 密钥的 `BiometryPolicy` 存在 `kSecAttrGeneric`（1 字节）；没有这个属性的旧条目
/// 是在只有 `.biometryAny` 时生成的，按 `.anyEnrolled` 读。这个兼容分支不能删：`xyz.unipass.signer`
/// 日常用的那把密钥（签名地址 0xc8F9…9A06）就是 2026-10-25 加入这个属性之前生成的旧条目。
public struct KeyStore: Sendable {
    public struct StoredKey: Sendable {
        public var key: any P256SigningKey
        /// SE 密钥生成时选的策略；软件后备没有。
        public var policy: BiometryPolicy?
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case keychain(OSStatus)
        case corrupted
        case secureEnclaveUnavailable
        /// 已经有一个密钥条目（哪怕读不出来）：生成新密钥前必须由用户在设置里明确删除。
        case keyExists
        /// 密钥能正常读出来：不能当作"读不出的密钥"删除。
        case keyReadable

        public var description: String {
            switch self {
            case .keychain(let s): "Keychain 错误 \(s)：\(SecCopyErrorMessageString(s, nil) as String? ?? "")"
            case .corrupted: "Keychain 里的密钥数据损坏"
            case .secureEnclaveUnavailable: "这台设备没有 Secure Enclave"
            case .keyExists: "已经有一个签名密钥条目，不会覆盖它"
            case .keyReadable: "签名密钥能正常读出，没有删除"
            }
        }
    }

    public var service: String
    public var account: String

    /// Keychain service 名取 App 自己的 Bundle ID（由构建配置决定，见 BUILDING.md）。
    /// UniPass 自己的构建是 `xyz.unipass.signer`，和以前写死的值一样，已有的密钥照常读得到。
    /// 这只是条目的标签：Keychain 条目本来就按 Team ID + Bundle ID 隔离，别的 App 读不到。
    public static var defaultService: String { Bundle.main.bundleIdentifier ?? "unipass-inkan-signer" }

    public init(service: String = KeyStore.defaultService, account: String = "owner-key-v0") {
        self.service = service
        self.account = account
    }

    public func load() throws -> StoredKey? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let item = out as? [CFString: Any],
              let blob = item[kSecValueData] as? Data,
              let tag = blob.first
        else {
            throw Failure.keychain(status)
        }
        let body = blob.dropFirst()
        switch SigningKeyKind(rawValue: tag) {
        case .secureEnclave:
            let policyByte = (item[kSecAttrGeneric] as? Data)?.first
            guard let policy = policyByte.map(BiometryPolicy.init(rawValue:)) ?? .anyEnrolled else {
                throw Failure.corrupted
            }
            return StoredKey(key: try SecureEnclaveSigningKey(dataRepresentation: Data(body)), policy: policy)
        case .softwareDebug:
            #if targetEnvironment(simulator) || DEBUG
            let key = SoftwareDebugSigningKey(privateKey: try P256.Signing.PrivateKey(rawRepresentation: body))
            return StoredKey(key: key, policy: nil)
            #else
            throw Failure.corrupted
            #endif
        case nil:
            throw Failure.corrupted
        }
    }

    /// 生成新密钥并保存。有 SE 就用 SE；没有时只有模拟器 / DEBUG 构建会退回软件密钥。
    /// `policy` 只对 SE 密钥有意义；软件后备忽略它。
    /// 已经有条目时（哪怕读不出来）拒绝生成，绝不覆盖：要换密钥，用户必须先在设置里明确删除（`delete()`）。
    public func generate(policy: BiometryPolicy) throws -> StoredKey {
        guard !hasEntry else { throw Failure.keyExists }
        if SecureEnclaveSigningKey.isAvailable {
            let key = try SecureEnclaveSigningKey.generate(policy: policy)
            try save(kind: .secureEnclave, body: key.dataRepresentation, policy: policy,
                     accessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly)
            return StoredKey(key: key, policy: policy)
        }
        #if targetEnvironment(simulator) || DEBUG
        let key = SoftwareDebugSigningKey()
        // 模拟器没有锁屏密码，WhenPasscodeSet 存不进去。
        try save(kind: .softwareDebug, body: key.privateKey.rawRepresentation, policy: nil,
                 accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        return StoredKey(key: key, policy: nil)
        #else
        throw Failure.secureEnclaveUnavailable
        #endif
    }

    /// Keychain 里有没有这个条目（不读内容，不触发 Face ID）。
    public var hasEntry: Bool {
        var query = baseQuery
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    /// 设置里"删除读不出的签名密钥"：删除前重读一次，能读出来就拒绝（`keyReadable`），条目不动。
    /// 读取失败可能只是暂时的（例如锁屏时读），所以不能凭 App 启动时的结果删。查询不带 `kSecAttrGeneric`，旧格式条目一样删。
    /// 没有条目时什么也不做。
    public func deleteUnreadable() throws {
        let stored: StoredKey?
        do { stored = try load() } catch {
            try delete()
            return
        }
        if stored != nil { throw Failure.keyReadable }
    }

    private func save(kind: SigningKeyKind, body: Data, policy: BiometryPolicy?, accessible: CFString) throws {
        var item = baseQuery
        item[kSecValueData] = Data([kind.rawValue]) + body
        if let policy { item[kSecAttrGeneric] = Data([policy.rawValue]) }
        item[kSecAttrAccessible] = accessible
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw Failure.keyExists }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }
}
