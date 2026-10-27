#if DEBUG
import UIKit
import WebKit

/// Debug-only performance harness. Launch with `-benchmark` to load a fixed set
/// of real pages under each blocking setup, each in a fresh cache-free web view,
/// and print one `BENCH` JSON line per page. Launch timing prints as `PERF`.
@MainActor
enum Benchmark {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-benchmark") }

    /// `-benchPage <url>` measures just that page, five times.
    static var pages: [String] {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-benchPage"), index + 1 < arguments.count { return [arguments[index + 1]] }
        return defaultPages
    }

    static let defaultPages = [
        "https://www.theverge.com",
        "https://edition.cnn.com",
        "https://www.bbc.com/news",
        "https://www.nytimes.com",
        "https://www.forbes.com",
        "https://www.cnet.com",
        "https://en.wikipedia.org/wiki/Web_browser",
    ]

    /// networkOnly: request blocking, no element hiding.
    /// legacy: request blocking plus every hiding rule handed to WebKit (the old way).
    /// onDemand: request blocking plus per-page hiding.
    /// consent: onDemand plus the cookie pop-up scripts (what the app ships).
    /// `-benchConsent` runs only the last two, to see what answering pop-ups costs.
    enum Variant: String, CaseIterable {
        case networkOnly, legacy, onDemand, consent
    }

    private static var variants: [Variant] {
        ProcessInfo.processInfo.arguments.contains("-benchConsent") ? [.onDemand, .consent] : Variant.allCases
    }

    private static var runsPerPage: Int { ProcessInfo.processInfo.arguments.contains("-benchPage") ? 5 : 3 }

    static func run() async {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            print("BENCH no window")
            return
        }
        await CosmeticFilter.shared.load()
        let lists = await compileLists()
        for variant in variants {
            for page in pages {
                guard let url = URL(string: page) else { continue }
                var samples: [[String: Double]] = []
                for _ in 0..<runsPerPage {
                    if let sample = await load(url, lists: lists[variant] ?? [],
                                               onDemandHiding: variant == .onDemand || variant == .consent,
                                               consent: variant == .consent, in: window) {
                        samples.append(sample)
                    }
                }
                report(variant: variant, page: page, samples: samples)
            }
        }
        print("BENCH done")
    }

    // MARK: Lists

    private static func compileLists() async -> [Variant: [WKContentRuleList]] {
        let store = WKContentRuleListStore.default()!
        var network: [WKContentRuleList] = []
        var legacy: [WKContentRuleList] = []

        func compile(_ rules: [[String: Any]], _ identifier: String) async -> WKContentRuleList? {
            guard let data = try? JSONSerialization.data(withJSONObject: rules),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        }
        func hide(_ selectors: [String], domains: [String]? = nil) -> [[String: Any]] {
            stride(from: 0, to: selectors.count, by: 400).map { start in
                var trigger: [String: Any] = ["url-filter": ".*"]
                if let domains { trigger["if-domain"] = domains.map { "*" + $0 } }
                let chunk = selectors[start..<min(start + 400, selectors.count)]
                return ["trigger": trigger, "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]]
            }
        }

        for name in ["ads", "privacy", "cookies"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let text = try? ContentBlocker.rules(json: url, hosts: Bundle.main.url(forResource: "\(name)-hosts", withExtension: "txt")),
                  let rules = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { continue }
            if let list = await compile(rules, "bench-net-\(name)") { network.append(list) }

            // Rebuild the old style: every hiding rule inside the WebKit list.
            var old: [[String: Any]] = []
            if let hideURL = Bundle.main.url(forResource: "\(name)-hide", withExtension: "txt"),
               let text = try? String(contentsOf: hideURL, encoding: .utf8) {
                // The same lines CosmeticFilter reads: keyed, every page, per site.
                var section = 0, everywhere: [String] = [], scoped: [String: [String]] = [:]
                for line in text.split(separator: "\n") {
                    if line.first == "\u{1}" { section += 1; continue }
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    switch section {
                    case 0: if parts.count == 2 { everywhere.append(parts[1]) }
                    case 1: everywhere.append(String(line))
                    case 2: if parts.count == 2 { scoped[parts[0], default: []].append(parts[1]) }
                    default: break
                    }
                }
                old += hide(everywhere)
                for (domain, selectors) in scoped { old += hide(selectors, domains: [domain]) }
            }
            if let list = await compile(old + rules, "bench-legacy-\(name)") { legacy.append(list) }
        }
        return [.networkOnly: network, .legacy: legacy, .onDemand: network, .consent: network]
    }

    // MARK: Loading

    private static func load(_ url: URL, lists: [WKContentRuleList], onDemandHiding: Bool, consent: Bool,
                             in window: UIWindow) async -> [String: Double]? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        lists.forEach(controller.add)
        if onDemandHiding, let script = CosmeticFilter.shared.script {
            controller.addUserScript(script)
            controller.addScriptMessageHandler(CosmeticFilter.shared, contentWorld: CosmeticFilter.world,
                                               name: CosmeticFilter.handlerName)
        }
        if consent {
            ConsentHandler.shared.scripts.forEach(controller.addUserScript)
            controller.addScriptMessageHandler(ConsentHandler.shared, contentWorld: ConsentHandler.world,
                                               name: ConsentHandler.handlerName)
        }
        configuration.userContentController = controller

        let webView = WKWebView(frame: window.bounds, configuration: configuration)
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        let start = CFAbsoluteTimeGetCurrent()
        let finished = await waiter.load(url, in: webView, timeout: 25)
        let wall = (CFAbsoluteTimeGetCurrent() - start) * 1000
        guard finished else { return ["timeout": 1, "wall": wall] }

        // Let late paint entries land.
        try? await Task.sleep(for: .milliseconds(400))
        let script = """
        const n = performance.getEntriesByType('navigation')[0] || {};
        const r = performance.getEntriesByType('resource');
        const fcp = performance.getEntriesByName('first-contentful-paint')[0];
        return { dcl: n.domContentLoadedEventEnd || 0, load: n.loadEventEnd || 0,
                 fcp: fcp ? fcp.startTime : 0, requests: r.length, nodes: document.getElementsByTagName('*').length,
                 hidden: [...document.querySelectorAll('body *')].filter(e => e.offsetParent === null && getComputedStyle(e).display === 'none').length };
        """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any]
        var sample = ["wall": wall]
        for (key, value) in result ?? [:] {
            if let number = value as? NSNumber { sample[key] = number.doubleValue }
        }
        return sample
    }

    private static func report(variant: Variant, page: String, samples: [[String: Double]]) {
        let keys = ["wall", "fcp", "dcl", "load", "requests", "nodes", "hidden"]
        var line: [String: Any] = ["variant": variant.rawValue, "page": page, "runs": samples.count,
                                   "timeouts": samples.filter { $0["timeout"] != nil }.count]
        let good = samples.filter { $0["timeout"] == nil }
        for key in keys {
            let values = good.compactMap { $0[key] }.sorted()
            if !values.isEmpty { line[key] = Int(values[values.count / 2]) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("BENCH \(text)")
        }
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func load(_ url: URL, in webView: WKWebView, timeout: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.finish(false)
            }
        }
    }

    private func finish(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }
}

#endif
