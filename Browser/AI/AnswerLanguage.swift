import Foundation
import FoundationModels
import NaturalLanguage

/// A language summaries, answers and notifications can be written in.
nonisolated struct WritingLanguage: Hashable, Identifiable {
    /// BCP 47, as iOS knows it: "hr", "sr-Latn".
    let code: String
    /// Its own name, as Settings lists it.
    let name: String
    /// Its English name, for the models' instructions.
    let english: String
    /// For languages close enough to be mixed up, which standard to keep to.
    var standard: String?

    var id: String { code }

    /// What the models are told.
    var instruction: String { "Write in \(standard ?? english)." }

    /// Apple's models write it well. They claim more than they manage: tested,
    /// they write Croatian, Serbian and Bosnian with Serbian words and broken
    /// endings whatever the prompt says, so those count as written badly.
    var appleWritesWell: Bool {
        let base = String(code.prefix { $0 != "-" })
        return !["hr", "sr", "bs"].contains(base) && SystemLanguageModel.default.supportsLocale(Locale(identifier: code))
    }

    static let english = WritingLanguage(code: "en", name: "English", english: "English")

    /// English first, then by their own names. Croatian, Serbian and Bosnian
    /// each name their standard: the models otherwise drift between them.
    static let all: [WritingLanguage] = [
        english,
        WritingLanguage(code: "bs", name: "Bosanski", english: "Bosnian",
                        standard: "standard Bosnian (ijekavica) in Latin script: Bosnian words, never Croatian or Serbian ones, even where a source is Croatian or Serbian"),
        WritingLanguage(code: "cs", name: "Čeština", english: "Czech"),
        WritingLanguage(code: "da", name: "Dansk", english: "Danish"),
        WritingLanguage(code: "de", name: "Deutsch", english: "German"),
        WritingLanguage(code: "es", name: "Español", english: "Spanish"),
        WritingLanguage(code: "fr", name: "Français", english: "French"),
        WritingLanguage(code: "hr", name: "Hrvatski", english: "Croatian",
                        standard: "standard Croatian (ijekavica): Croatian words, never Serbian or Bosnian ones, even where a source is Serbian or Bosnian"),
        WritingLanguage(code: "it", name: "Italiano", english: "Italian"),
        WritingLanguage(code: "hu", name: "Magyar", english: "Hungarian"),
        WritingLanguage(code: "nl", name: "Nederlands", english: "Dutch"),
        WritingLanguage(code: "nb", name: "Norsk", english: "Norwegian (Bokmål)"),
        WritingLanguage(code: "pl", name: "Polski", english: "Polish"),
        WritingLanguage(code: "pt", name: "Português", english: "Portuguese"),
        WritingLanguage(code: "ro", name: "Română", english: "Romanian"),
        WritingLanguage(code: "sk", name: "Slovenčina", english: "Slovak"),
        WritingLanguage(code: "sl", name: "Slovenščina", english: "Slovenian"),
        WritingLanguage(code: "sr-Latn", name: "Srpski (latinica)", english: "Serbian",
                        standard: "standard Serbian (ekavica) in Latin script: Serbian words, never Croatian or Bosnian ones, even where a source is Croatian or Bosnian"),
        WritingLanguage(code: "fi", name: "Suomi", english: "Finnish"),
        WritingLanguage(code: "sv", name: "Svenska", english: "Swedish"),
        WritingLanguage(code: "tr", name: "Türkçe", english: "Turkish"),
        WritingLanguage(code: "el", name: "Ελληνικά", english: "Greek"),
        WritingLanguage(code: "bg", name: "Български", english: "Bulgarian"),
        WritingLanguage(code: "mk", name: "Македонски", english: "Macedonian"),
        WritingLanguage(code: "ru", name: "Русский", english: "Russian"),
        WritingLanguage(code: "sr-Cyrl", name: "Српски (ћирилица)", english: "Serbian",
                        standard: "standard Serbian (ekavica) in Cyrillic script: Serbian words, never Croatian or Bosnian ones, even where a source is Croatian or Bosnian"),
        WritingLanguage(code: "uk", name: "Українська", english: "Ukrainian"),
        WritingLanguage(code: "ja", name: "日本語", english: "Japanese"),
        WritingLanguage(code: "ko", name: "한국어", english: "Korean"),
        WritingLanguage(code: "zh-Hans", name: "中文（简体）", english: "Simplified Chinese"),
    ]

    static func with(code: String) -> WritingLanguage? {
        all.first { $0.code == code }
    }

    /// A page's `lang` ("en-US", "hr", "sr-Latn-RS") as one of the listed languages.
    private static func stated(_ tag: String) -> WritingLanguage? {
        let parts = tag.split(separator: "-").map(String.init)
        guard let base = parts.first?.lowercased() else { return nil }
        if base == "sr" { return with(code: parts.contains("Cyrl") ? "sr-Cyrl" : "sr-Latn") }
        if base == "zh" { return with(code: "zh-Hans") }
        return with(code: base)
    }

    /// The language a page or question is written in. `declared`: what the
    /// page says it's in, trusted when the text alone isn't clear: an English
    /// Wikipedia article opening on a town's names in five languages read as Catalan.
    static func detected(in text: String, host: String = "", declared: String? = nil) -> WritingLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4_000)))
        let best = recognizer.languageHypotheses(withMaximum: 1).first
        if (best?.value ?? 0) < 0.8, let declared, let stated = stated(declared) { return stated }
        guard let code = best?.key.rawValue else { return nil }
        // Croatian, Serbian and Bosnian in Latin script read so alike that the
        // recognizer mixes them up: the site's country says which, else the phone's.
        if ["hr", "sr", "bs"].contains(code) {
            if text.prefix(400).unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                return with(code: "sr-Cyrl")
            }
            let byCountry = ["hr": "hr", "rs": "sr-Latn", "ba": "bs"]
            let site = host.split(separator: ".").last.map { String($0) } ?? ""
            let phone = Locale.current.region?.identifier.lowercased() ?? ""
            return with(code: byCountry[site] ?? byCountry[phone] ?? (code == "sr" ? "sr-Latn" : code))
        }
        if let known = all.first(where: { $0.code == code || $0.code.hasPrefix(code + "-") }) { return known }
        let names = (own: Locale(identifier: code).localizedString(forLanguageCode: code),
                     english: Locale(identifier: "en").localizedString(forLanguageCode: code))
        return WritingLanguage(code: code, name: names.own ?? code, english: names.english ?? code)
    }
}

/// Settings → Answer language: what summaries, Browse for Me and Notify Me
/// write in. Automatic (nothing stored) follows the page or the question.
/// With a language chosen, a page in it, or in one of the languages kept as
/// they are, is written about in its own language; any other page in the
/// chosen one. Say Croatian, keeping English: a Croatian or English article
/// stays as it is, a German one comes in Croatian.
nonisolated enum AnswerLanguage {
    static let key = "answerLanguage"
    static let keptKey = "answerLanguage.kept"

    static var chosen: WritingLanguage? {
        UserDefaults.standard.string(forKey: key).flatMap(WritingLanguage.with(code:))
    }

    /// Languages written in as they are, besides the chosen one.
    static var kept: [WritingLanguage] {
        (UserDefaults.standard.stringArray(forKey: keptKey) ?? []).compactMap(WritingLanguage.with(code:))
    }

    /// What to write in for this page or question; nil when it can't be told,
    /// and the models are left to follow it themselves.
    static func target(for text: String, host: String = "", declared: String? = nil) -> WritingLanguage? {
        let detected = WritingLanguage.detected(in: text, host: host, declared: declared)
        guard let chosen else { return detected }
        guard let detected else { return chosen }
        let own = [chosen] + kept
        // "sr-Latn" kept covers a page that reads as plain "sr" too.
        return own.contains { $0.code == detected.code || $0.code.hasPrefix(detected.code + "-") } ? detected : chosen
    }

    /// For telling cached summaries apart: the same page under other settings
    /// may be written in another language.
    static var signature: String {
        guard let chosen else { return "auto" }
        return ([chosen.code] + kept.map(\.code).sorted()).joined(separator: "+")
    }
}
