import Foundation
import Security

/// 钥匙串条目的 service 名都以 App 的 Bundle ID 开头：两份 App（比如录 demo 用的第二套，Bundle ID 不同）
/// 各用各的条目，不会读到对方的提交账户私钥、API key 或节点设置。这些条目在登录钥匙串里，
/// 名字一样的话第二份 App 会去读同一个条目。
/// 正式 App 的 Bundle ID 是 `xyz.unipass.coordinator`，所以名字和以前完全一样；命令行工具没有 Bundle ID，也用这个。
public enum KeychainNamespace {
    public static let fallback = "xyz.unipass.coordinator"

    public static func service(_ name: String, bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        "\(bundleID ?? fallback).\(name)"
    }
}

/// 一个钥匙串里的通用密码条目：只在这台 Mac 解锁时可用，不同步。
struct KeychainItem {
    let service: String
    var account = "default"

    func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func write(_ data: Data) throws {
        try delete()
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw SafeAPIKey.KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SafeAPIKey.KeychainError(status: status) }
    }
}
