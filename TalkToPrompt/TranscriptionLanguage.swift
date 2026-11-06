import Foundation

/// Input-language hints for speech recognition, rather than an output-language setting.
/// gpt-transcribe accepts ISO 639-1 codes plus the documented Chinese variants:
/// https://developers.openai.com/api/docs/guides/speech-to-text#supported-languages
struct TranscriptionLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }

    static let preferenceKey = "preferredTranscriptionLanguage"
    static let all: [TranscriptionLanguage] = {
        let english = Locale(identifier: "en")
        var choices = Locale.LanguageCode.isoLanguageCodes.compactMap { language -> TranscriptionLanguage? in
            let code = language.identifier
            guard code.count == 2, let name = english.localizedString(forLanguageCode: code) else { return nil }
            return .init(code: code, name: name)
        }
        choices += [
            .init(code: "yue", name: "Cantonese"),
            .init(code: "cmn", name: "Mandarin Chinese"),
            .init(code: "zh-cn", name: "Chinese (Mainland China)"),
            .init(code: "zh-hk", name: "Chinese (Hong Kong)"),
            .init(code: "zh-tw", name: "Chinese (Taiwan)")
        ]
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func validated(_ code: String?) -> String? {
        guard let code, all.contains(where: { $0.code == code }) else { return nil }
        return code
    }
}
