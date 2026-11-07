import Foundation
import WebKit

/// One Browse for Me page: a question and its answer, then each follow-up asked
/// from it as a new section below, answered with the page so far as context.
/// Also keeps the search engine's results for the latest question, so the page
/// can flip to them and back without losing either.
@Observable
final class BrowseSession: Identifiable {
    private(set) var turns: [BrowseForMeModel]

    /// Showing the search engine's results instead of the answers.
    var showsSearch = false {
        didSet { if showsSearch { loadSearchIfNeeded() } }
    }

    /// Its card in the tab switcher, and its file once it's closed (RecentAnswers).
    let answerID: UUID
    /// Asked from private browsing: nothing of it is kept.
    var isPrivate = false
    /// Opened from its card, not asked just now.
    let isRestored: Bool

    init(question: String, context: [(question: String, answer: String)] = []) {
        let first = BrowseForMeModel(query: question, context: context)
        turns = [first]
        answerID = UUID()
        isRestored = false
        first.start()
    }

    /// An answer opened again from its card: as it was, with nothing asked again.
    /// Follow-ups carry every answer before them, as for one asked just now.
    init(restoring answer: SavedAnswer, id: UUID) {
        var restored: [BrowseForMeModel] = []
        for turn in answer.turns {
            let context = restored.map { (question: $0.query, answer: $0.plainAnswer) }
            restored.append(BrowseForMeModel(restoring: turn, context: context))
        }
        turns = restored
        answerID = id
        isRestored = true
    }

    /// What's kept once it's closed: the questions answered in full, in order. Nil with none.
    var keepable: SavedAnswer? {
        let done = turns.prefix { $0.phase == .done }.compactMap(\.saved)
        return done.isEmpty ? nil : SavedAnswer(turns: done)
    }

    /// The card's lines: the first answer's opening, without its marks.
    var cardLines: [String] {
        let text = turns.first?.plainAnswer ?? ""
        return text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: #"^(#+|[-*>•]|=>|\d+\.)\s*"#, with: "", options: .regularExpression) }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "|", with: " · ") }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { String($0.prefix(160)) }
    }

    var latest: BrowseForMeModel { turns[turns.count - 1] }

    /// Asks a follow-up: a new section at the end, with every finished answer
    /// before it as context.
    func ask(_ question: String) {
        let context = turns.compactMap { turn in turn.phase == .done ? (question: turn.query, answer: turn.plainAnswer) : nil }
        let turn = BrowseForMeModel(query: question, context: context)
        turns.append(turn)
        turn.start()
    }

    /// Rewords one question: its section and every one after it are asked again.
    func reask(_ turn: BrowseForMeModel, as question: String) {
        guard let index = turns.firstIndex(where: { $0 === turn }) else { return }
        turns[index...].forEach { $0.cancel() }
        turns.removeSubrange(index...)
        ask(question)
    }

    /// Stops every answer still being written: the page was closed.
    func cancel() {
        turns.forEach { $0.cancel() }
    }

    // MARK: Search results

    /// A web view for the search engine's results, made the first time they're
    /// asked for: most answers never need it, and a web view isn't free.
    @ObservationIgnored private(set) var searchView: WKWebView?
    @ObservationIgnored private var searchedFor: String?
    @ObservationIgnored private let links = SearchLinks()

    private func loadSearchIfNeeded() {
        let question = latest.query
        guard searchedFor != question else { return }
        if searchView == nil {
            let webView = WebViewFactory.make(isPrivate: false)
            webView.uiDelegate = links
            searchView = webView
        }
        searchedFor = question
        searchView?.load(URLRequest(url: SearchEngine.current.searchURL(for: question)))
    }
}

/// Links that would open a new window open in the results view itself.
private final class SearchLinks: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}
