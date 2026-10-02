import Foundation
import Testing
@testable import TailCatCore

@Suite struct LocalizationTests {
    @Test func resolvesRegionalLanguagesAndFallsBackToEnglish() {
        for tag in ["en", "en-GB", "en-US"] {
            #expect(AppLanguage.resolve(preferredLanguages: [tag]) == .english)
        }
        for tag in ["zh-Hans", "zh-CN", "zh-SG"] {
            #expect(AppLanguage.resolve(preferredLanguages: [tag]) == .simplifiedChinese)
        }
        for tag in ["zh-Hant", "zh-TW", "zh-HK"] {
            #expect(AppLanguage.resolve(preferredLanguages: [tag]) == .traditionalChinese)
        }
        #expect(AppLanguage.resolve(preferredLanguages: ["fr-FR"]) == .english)
        #expect(AppLanguage.resolve(preferredLanguages: []) == .english)
        #expect(AppLanguage.resolve(preferredLanguages: ["de-DE", "zh-TW"]) == .traditionalChinese)
    }

    @Test func translatesAndPreservesDynamicData() {
        #expect(L10n.tr("检查更新", language: .english) == "Check for updates")
        #expect(L10n.tr("检查更新", language: .simplifiedChinese) == "检查更新")
        #expect(L10n.tr("检查更新", language: .traditionalChinese) == "檢查更新")
        #expect(L10n.tr("收到 %@", "report 100%.txt", language: .english) == "Received report 100%.txt")
        #expect(L10n.tr("收到 %@ 等 %d 项", "report.txt", 5, language: .english) == "Received report.txt and more (5 items total)")
        #expect(L10n.tr("unknown.key", language: .english) == "unknown.key")
    }

    @Test func preferencePersistsAndSynchronizesNativePanels() {
        let suite = "tailcat.language.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.language == .system)
        settings.language = .traditionalChinese
        #expect(AppSettings(defaults: defaults).language == .traditionalChinese)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hant"])
        settings.language = .system
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        defaults.set("unsupported", forKey: AppSettings.Key.language)
        #expect(settings.language == .system)
    }

    @Test func catalogsHaveMatchingKeysAndFormatArguments() throws {
        let source = try L10n.translations(for: .simplifiedChinese)
        #expect(!source.isEmpty)
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?((?:ll|l|z)?[@diufgeGs])"#)
        func arguments(_ text: String) -> [String] {
            let escaped = text.replacingOccurrences(of: "%%", with: "")
            let value = escaped as NSString
            return format.matches(in: escaped, range: NSRange(location: 0, length: value.length))
                .map { value.substring(with: $0.range(at: 1)) }.sorted()
        }
        for language in [AppLanguage.english, .traditionalChinese] {
            let translated = try L10n.translations(for: language)
            #expect(Set(translated.keys) == Set(source.keys))
            for (key, value) in translated {
                #expect(!value.isEmpty, "Empty translation: \(language.rawValue) / \(key)")
                #expect(arguments(key) == arguments(value), "Format mismatch: \(language.rawValue) / \(key)")
            }
        }
    }

    @Test func everyLiteralKeyHasTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\(\s*("(?:[^"\\]|\\.)*")"#)
        let keys = Set(try L10n.translations(for: .simplifiedChinese).keys)
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url)
            let text = source as NSString
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let literal = text.substring(with: match.range(at: 1))
                // Keys are static strings; values go through format arguments, never interpolation.
                let key = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as! String
                #expect(keys.contains(key), "Missing key in \(url.lastPathComponent): \(key)")
            }
        }
    }
}
