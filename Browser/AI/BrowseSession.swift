import Foundation
import WebKit

/// One Browse for Me page: a question and its answer, then each follow-up asked
/// from it as a new section below, answered with the page so far as context.
/// Also keeps the search engine's results for the latest question, so the page
/// can flip to them and back without losing either.
@Observable
final class BrowseSession: Identifiable {
    private(set) var turns: [BrowseForMeModel]
    /// Its link, once shared (AnswerSharing).
    var shared: AnswerSharing.Shared?
    /// Uploading for a share right now.
    var isSharing = false

    /// Showing the search engine's results instead of the answers.
    var showsSearch = false {
        didSet { if showsSearch { loadSearchIfNeeded() } }
    }

    init(question: String, context: [(question: String, answer: String)] = []) {
        let first = BrowseForMeModel(query: question, context: context)
        turns = [first]
        first.start()
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
