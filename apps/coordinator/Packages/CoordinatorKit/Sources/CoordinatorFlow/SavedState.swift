import Foundation

/// 存在 UserDefaults 里的状态（配对的签名器、Safe 列表、欢迎引导走完没有）和启动时的读取。都是公开数据。
/// 只读当前的键，不迁移旧版本的数据（只发源码，没有要迁移的老用户）。
public struct SavedState {
    public static let pairedSignersKey = "pairedSigners.v1"
    public static let safesKey = "safes.v1"
    public static let onboardedKey = "onboarded.v1"
    public static let addressBookKey = "addressBook.v1"

    public var signers: PairedSigners
    public var store: SafeStore
    public var onboarded: Bool

    public static func load(_ defaults: UserDefaults) -> SavedState {
        SavedState(
            signers: PairedSigners.load(defaults.data(forKey: pairedSignersKey)),
            store: defaults.data(forKey: safesKey).flatMap { try? SafeStore(decoding: $0) } ?? SafeStore(),
            onboarded: defaults.bool(forKey: onboardedKey))
    }
}
