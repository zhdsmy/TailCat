import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public var name: String {
        switch self {
        case .system: return L10n.tr("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }

    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        let supported = [english, simplifiedChinese, traditionalChinese].map(\.rawValue)
        let match = Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first
        return match.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

/// One resource bundle for SwiftUI, Foundation errors, notifications and diagnostics.
/// Configure once before creating the app; switching preferences takes effect on next launch.
public enum L10n {
    private static let lock = NSLock()
    // The core library's source language also keeps tests independent of the host's preferences.
    private static var current: AppLanguage = .simplifiedChinese
    // A packaged app has no SwiftPM build directory; older toolchains only search beside the executable.
    private static let resources = Bundle.main.url(forResource: "TailCat_TailCatCore", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    private static let bundles: [AppLanguage: Bundle] = {
        Dictionary(uniqueKeysWithValues: AppLanguage.allCases.filter { $0 != .system }.map { language in
            guard let url = resources.url(forResource: language.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else {
                preconditionFailure("Missing localization resources: \(language.rawValue)")
            }
            return (language, bundle)
        })
    }()

    public static var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public static func configure(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        lock.lock()
        defer { lock.unlock() }
        current = language == .system ? AppLanguage.resolve(preferredLanguages: preferredLanguages) : language
    }

    public static func tr(_ key: String, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        let resolved = selected == .system ? AppLanguage.resolve(preferredLanguages: Locale.preferredLanguages) : selected
        let fallback = bundles[.english]!.localizedString(forKey: key, value: key, table: nil)
        let format = bundles[resolved]!.localizedString(forKey: key, value: fallback, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: resolved.rawValue), arguments: arguments)
    }

    /// Exposed to @testable tests so missing translations fail before packaging.
    static func translations(for language: AppLanguage) throws -> [String: String] {
        let url = bundles[language]!.url(forResource: "Localizable", withExtension: "strings")!
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    }
}
