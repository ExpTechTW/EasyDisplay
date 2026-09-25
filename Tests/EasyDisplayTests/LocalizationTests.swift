import Foundation
import Testing
@testable import EasyDisplay

@Suite(.serialized) struct LocalizationTests {
    /// Reads a strings file from the sources, so the check doesn't depend on the built bundle.
    private func table(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EasyDisplay/Resources/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "\(url.path)")
    }

    private func placeholders(_ text: String) -> [String] {
        text.matches(of: #/%(?:\d+\$)?[@dfs]/#).map { String($0.output) }.sorted()
    }

    @Test func everyLanguageHasEveryStringWithTheSamePlaceholders() throws {
        let english = try table("en")
        for language in ["zh-Hant", "ja"] {
            let other = try table(language)
            #expect(Set(other.keys) == Set(english.keys), "\(language) has different keys")
            for (key, value) in english {
                #expect(placeholders(other[key] ?? "") == placeholders(value), "\(language): \(key)")
            }
        }
    }

    @Test func everyKeyTheSourcesUseExists() throws {
        let english = try table("en")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EasyDisplay")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: #/\bLF?\("([a-z0-9_.]+)"/#) {
                #expect(english[String(match.output.1)] != nil, "\(file.lastPathComponent): \(match.output.1)")
            }
        }
    }

    /// Keys built at runtime, which the scan of the sources can't see.
    @Test func pagesAndRangesHaveTheirStrings() throws {
        let english = try table("en")
        for page in SettingsPage.allCases {
            #expect(english["settings.page.\(page.rawValue)"] != nil && english["settings.page.\(page.rawValue)_subtitle"] != nil, "\(page)")
        }
        for range in MonitorRange.allCases {
            #expect(english["monitor.range.\(range.rawValue)"] != nil && english["monitor.span.\(range.rawValue)"] != nil, "\(range)")
        }
        for period in MonitorAnalysisSection.Period.allCases {
            #expect(english["analysis.period.\(period.rawValue)"] != nil, "\(period)")
        }
    }

    @Test func switchingLanguageChangesStringsImmediately() {
        defer { AppLanguage.stored.apply() }
        AppLanguage.japanese.apply()
        #expect(L("tray.brightness") == "明るさ")
        AppLanguage.traditionalChinese.apply()
        #expect(L("tray.brightness") == "亮度")
        #expect(LF("language.system", "English") == "跟隨系統（English）")
        AppLanguage.english.apply()
        #expect(L("tray.brightness") == "Brightness")
        #expect(L("no.such.key") == "no.such.key")
    }

    @Test func languagesAreNamedInThemselves() {
        #expect(AppLanguage.traditionalChinese.displayName == "繁體中文")
        #expect(AppLanguage.japanese.displayName == "日本語")
        #expect(AppLanguage.english.displayName == "English")
    }
}
