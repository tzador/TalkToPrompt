import Combine
import Foundation

struct TranslationLanguage: Equatable, Sendable, Codable {
    let code: String
    let name: String

    /// English language names, independent of the user's system language.
    static let all: [TranslationLanguage] = {
        let english = Locale(identifier: "en")
        var codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
        codes.formUnion(["yue", "fil"])
        return codes.sorted().compactMap { code in
            guard let name = english.localizedString(forLanguageCode: code) else { return nil }
            return TranslationLanguage(code: code, name: name)
        }
    }()
}

@MainActor
final class DictationLanguageModel: ObservableObject {
    static let defaultsKey = "dictationTranslationLanguage"
    @Published private(set) var activeLanguage: TranslationLanguage?
    var displayName: String { activeLanguage?.name ?? "Auto" }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let code = defaults.string(forKey: Self.defaultsKey)
        activeLanguage = TranslationLanguage.all.first { $0.code == code }
    }

    /// Commands must occupy the entire transcript. Bare language names and
    /// command phrases embedded in a sentence remain ordinary dictation.
    @discardableResult
    func handleCommand(_ transcript: String) -> Bool {
        let command = Self.normalize(transcript)
        if ["don't translate", "do not translate", "no translation", "translation off", "translation none"].contains(command) {
            activeLanguage = nil
            defaults.removeObject(forKey: Self.defaultsKey)
            return true
        }
        let prefix = "translate to "
        guard command.hasPrefix(prefix),
              let language = Self.commands[String(command.dropFirst(prefix.count))] else { return false }
        activeLanguage = language
        defaults.set(language.code, forKey: Self.defaultsKey)
        return true
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let commands: [String: TranslationLanguage] = {
        var result: [String: TranslationLanguage] = [:]
        for language in TranslationLanguage.all where result[normalize(language.name)] == nil {
            result[normalize(language.name)] = language
        }
        let aliases = ["mandarin": "zh", "mandarin chinese": "zh", "cantonese": "yue",
                       "farsi": "fa", "persian": "fa", "bengali": "bn", "bangla": "bn",
                       "filipino": "fil", "burmese": "my", "greek": "el", "hebrew": "he"]
        for (name, code) in aliases {
            if let language = TranslationLanguage.all.first(where: { $0.code == code }) { result[name] = language }
        }
        return result
    }()
}
