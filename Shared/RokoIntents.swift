import AppIntents
import Foundation

/// roko from outside: Siri, Shortcuts, Spotlight, Control Center, the Lock
/// Screen and the Action button. Each opens roko on one of its own links
/// (BrowserModel.handleLink), so they work the same from the app or the
/// widgets extension.
struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab"
    static let description = IntentDescription("Opens roko's bar, ready to type or speak.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "roko://new-tab")!))
    }
}

struct PrivateTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Tab"
    static let description = IntentDescription("Opens roko's bar for a private tab, which leaves nothing behind.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "roko://private-tab")!))
    }
}

struct AskRokoIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask roko"
    static let description = IntentDescription("roko reads the web for you and answers, with its sources.")

    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String?

    func perform() async throws -> some IntentResult & OpensIntent {
        var link = URLComponents(string: "roko://ask")!
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            link.queryItems = [URLQueryItem(name: "q", value: String(question.prefix(300)))]
        }
        return .result(opensIntent: OpenURLIntent(link.url!))
    }
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in roko"
    static let description = IntentDescription("Opens a web page in a new roko tab.")

    @Parameter(title: "Page") var page: URL

    func perform() async throws -> some IntentResult & OpensIntent {
        var link = URLComponents(string: "roko://open")!
        link.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        return .result(opensIntent: OpenURLIntent(link.url!))
    }
}
