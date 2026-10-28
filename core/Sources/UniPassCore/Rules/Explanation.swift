import Foundation

/// 一句白话解释：模板 key + 参数，按语言渲染（模板在 `Resources/Localizable.xcstrings`）。
///
/// 外部字符串（地址簿名、标签库里的代币名）只作为 `.text` 参数插进去：渲染时加引号、
/// 去掉控制字符和方向 / 零宽格式字符、截断长度——它们永远是被引用的数据，不会变成句子的一部分。
public struct Explanation: Hashable, Sendable {
    public indirect enum Arg: Hashable, Sendable {
        case address(AddressInfo)
        case amount(TokenAmount)
        /// 外部字符串。
        case text(String)
        /// 我们自己生成的短串（数字、规则号、选择器）。
        case plain(String)
        /// Unix 时间（秒），按 UTC 显示；0 显示为"立即过期"。
        case timestamp(UInt64)
        /// 嵌套的一句解释（例如 DELEGATECALL 时调用数据"表面上"是什么）。
        case nested(Explanation)
    }

    public var key: String
    public var args: [Arg]

    public init(_ key: String, _ args: Arg...) {
        self.key = key
        self.args = args
    }

    public enum Language: String, Sendable, CaseIterable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"
    }

    /// `language` 为 nil 时按系统语言。
    public func render(_ language: Language? = nil) -> String {
        let bundle = language.flatMap { Bundle.module.path(forResource: $0.rawValue, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? .module
        let lang = language ?? (bundle.preferredLocalizations.first == "zh-Hans" ? .simplifiedChinese : .english)
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        let rendered = args.map { Self.render($0, lang, bundle, language) }
        return String(format: format, arguments: rendered.map { $0 as CVarArg })
    }

    static func render(_ arg: Arg, _ lang: Language, _ bundle: Bundle, _ requested: Language?) -> String {
        switch arg {
        case .address(let a):
            let short = Self.shortAddress(a.address)
            guard let label = a.label else { return short }
            return quote(sanitize(label), lang) + " (" + short + ")"
        case .amount(let amt):
            if amt.decimals == nil {
                let unit = bundle.localizedString(forKey: "amount.rawUnits", value: "raw units", table: nil)
                return amt.formatted + " " + unit + (amt.symbol.map { " " + quote(sanitize($0), lang) } ?? "")
            }
            return amt.formatted + (amt.symbol.map { " " + sanitize($0) } ?? "")
        case .text(let s):
            return quote(sanitize(s), lang)
        case .plain(let s):
            return s
        case .timestamp(let t):
            if t == 0 { return bundle.localizedString(forKey: "timestamp.zero", value: "immediately", table: nil) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
            return f.string(from: Date(timeIntervalSince1970: TimeInterval(min(t, 253_402_300_799))))
        case .nested(let e):
            return e.render(requested)
        }
    }

    /// `0xAbCd1234…5678EfAb`（EIP-55，前 8 后 8）。前后各 4 位的仿冒地址很容易算出来，8+8 算不出来。
    /// 完整地址由确认页另外显示。
    public static func shortAddress(_ a: Address) -> String {
        let s = a.checksummed
        return String(s.prefix(10)) + "…" + String(s.suffix(8))
    }

    static func quote(_ s: String, _ lang: Language) -> String {
        lang == .simplifiedChinese ? "“\(s)”" : "\"\(s)\""
    }

    /// 外部字符串的清理：去掉控制字符（Cc）和格式字符（Cf，包括 RLO/LRI 等方向控制符和零宽字符），
    /// 折叠空白，最多 32 个字符。
    public static func sanitize(_ s: String, maxLength: Int = 32) -> String {
        let scalars = s.unicodeScalars.filter { u in
            let c = u.properties.generalCategory
            return c != .control && c != .format
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.count > maxLength ? String(cleaned.prefix(maxLength - 1)) + "…" : cleaned
    }
}
