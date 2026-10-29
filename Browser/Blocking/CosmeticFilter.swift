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

    /// One list's hiding rules, read off the main thread from the lines
    /// Scripts/build_blocklists.py writes ("key<TAB>selector", then sections
    /// each opened by a \u{1} line): half the time the same index took as JSON.
    /// Substrings of the file's text, so reading copies nothing.
    private nonisolated struct Index: Sendable {
        var keyed: [Substring: [Substring]] = [:]
        var always: [Substring] = []
        var scoped: [Substring: [Substring]] = [:]
        var untouched: [Substring] = []

        init(text: String) {
            var section = 0
            for line in text.split(separator: "\n") {
                if line.first == "\u{1}" {
                    section += 1
                    continue
                }
                switch section {
                case 0, 2:
                    guard let tab = line.firstIndex(of: "\t") else { continue }
                    let key = line[..<tab], selector = line[line.index(after: tab)...]
                    if section == 0 { keyed[key, default: []].append(selector) } else { scoped[key, default: []].append(selector) }
                case 1: always.append(line)
                default: untouched.append(line)
                }
            }
        }
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

    /// Reads the indexes off the main thread, in parallel.
    private func decodeAll() async {
        let files = ContentBlocker.Category.allCases.compactMap { category in
            Bundle.main.url(forResource: "\(category.rawValue)-hide", withExtension: "txt").map { (category, $0) }
        }
        await withTaskGroup(of: (ContentBlocker.Category, Index?).self) { group in
            for (category, url) in files {
                group.addTask(priority: .userInitiated) {
                    (category, (try? String(contentsOf: url, encoding: .utf8)).map(Index.init(text:)))
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

        var selectors: [Substring] = []
        // Cookie banners are faded out rather than removed: the consent script
        // (ConsentHandler) has to find a banner to answer it, and a removed one
        // can't be found. The page script removes them for good a little later.
        var faded: [Substring] = []
        // Overlays (cookie banners, pop-ups) often lock page scrolling; the page
        // script checks these against the page and unlocks it if one was hidden.
        var overlays: [Substring] = []
        // Whether the page script may fold away ad boxes left empty by blocking.
        var collapseAds = false
        for category in ContentBlocker.Category.allCases where ContentBlocker.shared.isEnabled(category) {
            guard let index = indexes[category], !hosts.contains(where: { index.untouched.contains(Substring($0)) }),
                  !ContentBlocker.shared.isAllowed(host: host, category: category) else { continue }
            if category == .ads { collapseAds = true }
            var found: [Substring] = []
            if isFirst {
                found += index.always
                for host in hosts { found += index.scoped[Substring(host)] ?? [] }
            }
            for key in keys { found += index.keyed[Substring(key)] ?? [] }
            if category == .cookies { faded += found } else { selectors += found }
            if category == .cookies || category == .popups { overlays += found }
        }
        // What you hid on this site yourself: with the first answer, as the
        // site's own rules are. Overlays among them may have locked scrolling.
        if isFirst {
            let mine = HiddenItems.shared.selectors(for: host).map { Substring($0) }
            selectors += mine
            overlays += mine
        }
        // One rule per selector, so a selector WebKit can't parse only drops itself.
        // Under :root, one step more specific than the page's own rules: a site
        // whose stylesheet loads later and shows the same element with
        // !important (The Independent's membership offer) can't undo it.
        // Not for pseudo-elements, which :is() can't hold.
        let css = selectors.map { ($0.contains("::") ? String($0) : ":root :is(\($0))") + "{display:none!important}" }
            .joined(separator: "\n")
        if LaunchClock.isEnabled {
            print("HIDE \(host) keys=\(keys.count) first=\(isFirst) selectors=\(selectors.count) faded=\(faded.count)")
        }
        return (["css": css, "faded": faded.map(String.init), "overlays": overlays.map(String.init),
                 "collapseAds": isFirst && collapseAds], nil)
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
