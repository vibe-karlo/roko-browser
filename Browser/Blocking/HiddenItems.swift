import Foundation
import WebKit

/// Things you hid on a site yourself (Hide Distracting Items): a few CSS
/// selectors per site, kept on this iPhone. They reach a page with the first
/// hiding answer it already asks for (CosmeticFilter), so a site with nothing
/// hidden costs nothing, and one with something hidden pays one lookup.
@MainActor
final class HiddenItems {
    static let shared = HiddenItems()
    private static let key = "hiddenItems"

    private var bySite: [String: [String]]

    private init() {
        bySite = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    /// "www.thesun.co.uk" and "thesun.co.uk" are one site.
    static func site(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func selectors(for host: String) -> [String] {
        bySite[Self.site(host)] ?? []
    }

    func add(_ selectors: [String], for host: String) {
        guard !selectors.isEmpty else { return }
        var list = bySite[Self.site(host)] ?? []
        for selector in selectors where !list.contains(selector) { list.append(selector) }
        bySite[Self.site(host)] = list
        save()
    }

    /// Undo: the last one hidden comes back.
    func remove(_ selector: String, for host: String) {
        var list = bySite[Self.site(host)] ?? []
        list.removeAll { $0 == selector }
        bySite[Self.site(host)] = list.isEmpty ? nil : list
        save()
    }

    func forget(_ host: String) {
        bySite[Self.site(host)] = nil
        save()
    }

    /// Every site with something hidden, and how many things.
    func all() -> [String: Int] {
        bySite.mapValues(\.count)
    }

    private func save() {
        UserDefaults.standard.set(bySite, forKey: Self.key)
    }
}

/// The mode itself: roko's picker script in its own content world, put into
/// the page only when asked for and taken out when done.
@MainActor
final class HiddenItemsPicker: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "hideItems")
    static let handlerName = "hideItems"

    private static let source: String? = Bundle.main.url(forResource: "hide-items", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private weak var webView: WKWebView?
    private var host = ""
    /// What was hidden this time, in order, for Undo.
    private(set) var hidden: [String] = []
    var changed: ((Int) -> Void)?

    func start(in webView: WKWebView) {
        guard let source = Self.source, let host = webView.url?.host() else { return }
        self.webView = webView
        self.host = host
        hidden = []
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        webView.evaluateJavaScript(source, in: nil, in: Self.world, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "hidden",
              let selector = body["selector"] as? String, !selector.isEmpty else { return }
        hidden.append(selector)
        HiddenItems.shared.add([selector], for: host)
        changed?(hidden.count)
    }

    func undo() {
        guard let last = hidden.popLast() else { return }
        HiddenItems.shared.remove(last, for: host)
        webView?.evaluateJavaScript("window.__rokoHideItems && window.__rokoHideItems.undo()", in: nil, in: Self.world, completionHandler: nil)
        changed?(hidden.count)
    }

    /// Ends the mode; what was hidden stays hidden. Returns how many.
    @discardableResult
    func finish() -> Int {
        webView?.evaluateJavaScript("window.__rokoHideItems && window.__rokoHideItems.finish()", in: nil, in: Self.world, completionHandler: nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        webView = nil
        let count = hidden.count
        hidden = []
        return count
    }
}
