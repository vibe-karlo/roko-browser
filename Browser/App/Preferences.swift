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

    /// The languages dictation listens for.
    enum VoiceLanguages: String, CaseIterable, Identifiable {
        case both, english, croatian
        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: "Croatian and English"
            case .english: "English"
            case .croatian: "Croatian"
            }
        }
        var codes: [String] {
            switch self {
            case .both: ["hr-HR", "en-US"]
            case .english: ["en-US"]
            case .croatian: ["hr-HR"]
            }
        }
    }

    static var voiceLanguages: VoiceLanguages {
        UserDefaults.standard.string(forKey: voiceLanguagesKey).flatMap(VoiceLanguages.init) ?? .both
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
