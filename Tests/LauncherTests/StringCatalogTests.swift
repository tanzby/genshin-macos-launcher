import Foundation
import Testing

/// The app's only user-facing strings live in `App/Localizable.xcstrings` (zh-Hans and en). Every entry needs
/// both languages, and a translation must carry the same format placeholders as its key.
@Suite struct StringCatalogTests {
  private static let catalogURL = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "App/Localizable.xcstrings")

  private func entries() throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: Self.catalogURL)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["sourceLanguage"] as? String == "en")
    return try #require(root["strings"] as? [String: [String: Any]])
  }

  private func value(_ entry: [String: Any], _ language: String) -> String? {
    let localizations = entry["localizations"] as? [String: Any]
    let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    return unit?["value"] as? String
  }

  private func placeholders(_ text: String) -> [String] {
    text.matches(of: /%(?:\d+\$)?(?:lld|ld|d|@|f)/).map { String($0.output) }.sorted()
  }

  @Test func catalogHasEnglishAndSimplifiedChineseForEveryKey() throws {
    let entries = try entries()
    #expect(!entries.isEmpty)
    for (key, entry) in entries {
      #expect(value(entry, "en")?.isEmpty == false, "en missing for \(key)")
      #expect(value(entry, "zh-Hans")?.isEmpty == false, "zh-Hans missing for \(key)")
    }
  }

  @Test func translationsKeepTheKeysPlaceholders() throws {
    for (key, entry) in try entries() {
      let expected = placeholders(key)
      #expect(placeholders(value(entry, "en") ?? "") == expected, "en placeholders differ for \(key)")
      #expect(placeholders(value(entry, "zh-Hans") ?? "") == expected, "zh-Hans placeholders differ for \(key)")
    }
  }
}
