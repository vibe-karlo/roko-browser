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

    lazy var script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "cosmetic-filter", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
    }()

    /// Loads the hiding indexes off the main thread (about 2 MB of JSON).
    func load() async {
        for category in ContentBlocker.Category.allCases {
            guard let url = Bundle.main.url(forResource: "\(category.rawValue)-hide", withExtension: "json") else { continue }
            let index = try? await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
            }.value
            indexes[category] = index
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let keys = body["keys"] as? [String] else {
            return (nil, nil)
        }
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
