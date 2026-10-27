import Foundation

/// The switches for roko's own features, read where each feature runs. Every
/// one is on unless it's been turned off in Settings.
enum Preferences {
    static let holdToTalkKey = "voice.holdToTalk"
    static let voiceLanguagesKey = "voice.languages"
    static let launcherTicksKey = "launcher.ticks"
    static let pullToSummarizeKey = "pull.summarize"
    static let todoAlertsKey = "todo.alerts"

    private static func on(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Holding + listens; off, + only opens the bar.
    static var holdToTalk: Bool { on(holdToTalkKey) }
    /// A light tick for each row that passes while the bar's list scrolls.
    static var launcherTicks: Bool { on(launcherTicksKey) }
    /// Pulling a page well past the reload point summarizes it.
    static var pullToSummarize: Bool { on(pullToSummarizeKey) }
    /// A notification 15 minutes before a to-do's time.
    static var todoAlerts: Bool { on(todoAlertsKey) }

    /// The languages dictation listens for: "both" (the phone's, see
    /// `Audience.voiceLanguages`), or one language code. "english" and
    /// "croatian" are how earlier versions stored the single choices.
    static var voiceLanguages: [String] {
        let all = Audience.voiceLanguages
        switch UserDefaults.standard.string(forKey: voiceLanguagesKey) ?? "both" {
        case "english": return ["en"]
        case "croatian": return ["hr"]
        case let code where all.contains(code): return [code]
        default: return all
        }
    }

    /// "English", "English or German": the languages dictation hears, by name.
    static var voiceLanguageNames: String {
        voiceLanguages.map(Audience.name(of:)).joined(separator: " or ")
    }
}

/// Who roko is talking to, read from the phone's own region and languages,
/// so a phone in Croatia gets Croatian news sites, voice and translation and
/// any other phone never sees them.
nonisolated enum Audience {
    /// The phone's languages, its first first, as codes: ["en", "hr"].
    static var languages: [String] {
        Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    static var isCroatian: Bool {
        Locale.current.region?.identifier == "HR" || languages.contains("hr")
    }

    /// What dictation listens for: the phone's first two languages, with
    /// English alongside a single other one (web addresses and product names
    /// are often said in English).
    static var voiceLanguages: [String] {
        var codes = Array(spoken.prefix(2))
        if codes.isEmpty { codes = ["en"] }
        if codes.count == 1, codes[0] != "en" { codes.append("en") }
        return codes
    }

    /// The phone's languages, and the language of where it is when that isn't
    /// among them: an English phone in Croatia also gets Croatian.
    static var spoken: [String] {
        guard let local = regionLanguage, !languages.contains(local) else { return languages }
        return languages.prefix(1) + [local] + languages.dropFirst()
    }

    /// The main language of the phone's region: "hr" in Croatia, "en" in the US.
    static var regionLanguage: String? {
        guard let region = Locale.current.region?.identifier else { return nil }
        return Locale.Language(identifier: "und-\(region)").maximalIdentifier.split(separator: "-").first.map(String.init)
    }

    /// A language's name in the phone's language: "English", "German".
    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    /// DuckDuckGo's region setting, "us-en", "hr-hr": results for where the
    /// phone is, in that place's language. "wt-wt" is no region at all.
    static var duckDuckGoRegion: String {
        guard let region = Locale.current.region?.identifier else { return "wt-wt" }
        return "\(region == "GB" ? "uk" : region.lowercased())-\(regionLanguage ?? "en")"
    }
}

extension URLSession {
    /// For the small fetches around the app (weather, rates, icons, suggestions,
    /// news): given up after ten seconds, so offline nothing spins for a minute.
    nonisolated static let quick: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
}
