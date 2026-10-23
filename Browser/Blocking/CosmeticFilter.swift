import Foundation
import WebKit

/// Serves element-hiding rules page by page. WebKit applies every site-agnostic
/// hiding rule in a content rule list to every page as one huge stylesheet,
/// which measurably delays first paint; here a page only receives the few
/// selectors whose id or class it actually contains (cosmetic-filter.js).
@MainActor
final class CosmeticFilter: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = CosmeticFilter()
    static let world = WKContentWorld.world(name: "cosmetic")
    static let handlerName = "cosmetic"

    // Decoded off the main thread, so its conformance can't be main-actor bound.
    private nonisolated struct Index: Decodable, Sendable {
        let keyed: [String: [String]]
        let always: [String]
        let scoped: [String: [String]]
        let untouched: [String]
    }

    private var indexes: [ContentBlocker.Category: Index] = [:]
    /// The indexes, decoded once, all at the same time. Pages don't wait for
    /// this: their first hiding request does, a few milliseconds later at most.
    private lazy var loading = Task { await decodeAll() }

    lazy var script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "cosmetic-filter", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
    }()

    /// Starts loading the hiding indexes, or waits for the load under way.
    func load() async {
        await loading.value
    }

    /// Decodes the indexes (about 3 MB of JSON) off the main thread, in parallel.
    private func decodeAll() async {
        let files = ContentBlocker.Category.allCases.compactMap { category in
            Bundle.main.url(forResource: "\(category.rawValue)-hide", withExtension: "json").map { (category, $0) }
        }
        await withTaskGroup(of: (ContentBlocker.Category, Index?).self) { group in
            for (category, url) in files {
                group.addTask(priority: .userInitiated) {
                    (category, try? JSONDecoder().decode(Index.self, from: Data(contentsOf: url)))
                }
            }
            for await (category, index) in group { indexes[category] = index }
        }
        LaunchClock.mark("hidingReady")
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let keys = body["keys"] as? [String] else {
            return (nil, nil)
        }
        await load()
        let host = (body["host"] as? String ?? "").lowercased()
        let isFirst = body["first"] as? Bool ?? false
        let hosts = Self.suffixes(of: host)

        var selectors: [String] = []
        // Overlays (cookie banners, pop-ups) often lock page scrolling; the page
        // script checks these against the page and unlocks it if one was hidden.
        var overlays: [String] = []
        // Whether the page script may fold away ad boxes left empty by blocking.
        var collapseAds = false
        for category in ContentBlocker.Category.allCases where ContentBlocker.shared.isEnabled(category) {
            guard let index = indexes[category], !hosts.contains(where: index.untouched.contains),
                  !ContentBlocker.shared.isAllowed(host: host, category: category) else { continue }
            if category == .ads { collapseAds = true }
            var found: [String] = []
            if isFirst {
                found += index.always
                for host in hosts { found += index.scoped[host] ?? [] }
            }
            for key in keys { found += index.keyed[key] ?? [] }
            selectors += found
            if category == .cookies || category == .popups { overlays += found }
        }
        // One rule per selector, so a selector WebKit can't parse only drops itself.
        let css = selectors.map { $0 + "{display:none!important}" }.joined(separator: "\n")
        if LaunchClock.isEnabled {
            print("HIDE \(host) keys=\(keys.count) first=\(isFirst) selectors=\(selectors.count)")
        }
        return (["css": css, "overlays": overlays, "collapseAds": isFirst && collapseAds], nil)
    }

    /// "news.bbc.co.uk" → ["news.bbc.co.uk", "bbc.co.uk", "co.uk", "uk"].
    private static func suffixes(of host: String) -> [String] {
        var parts = host.split(separator: ".")
        var result: [String] = []
        while !parts.isEmpty {
            result.append(parts.joined(separator: "."))
            parts.removeFirst()
        }
        return result
    }
}
