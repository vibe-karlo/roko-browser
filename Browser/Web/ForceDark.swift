import UIKit
import WebKit

/// Settings → Appearance → Force dark pages: every site dark, with a switch to
/// leave one out in its page menu. A site's own dark mode comes first; only a
/// page still light after that is flipped (force-dark.js). Off, which is the
/// default, a page gets no script and no style, and a navigation does nothing
/// here but read one setting.
enum ForceDark {
    static let key = "pages.forceDark"
    /// What shows before a page has drawn, and behind one with no background.
    static let canvas = UIColor.black

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    static func applies(to host: String?) -> Bool {
        guard isOn, let host else { return false }
        return !isLeftOut(host)
    }

    // MARK: Sites left out

    static func isLeftOut(_ host: String) -> Bool {
        UserDefaults.standard.bool(forKey: siteKey(host))
    }

    static func leaveOut(_ host: String, _ leftOut: Bool) {
        if leftOut {
            UserDefaults.standard.set(true, forKey: siteKey(host))
        } else {
            UserDefaults.standard.removeObject(forKey: siteKey(host))
        }
    }

    /// Every site left out: for Settings → Sites.
    static func sitesLeftOut() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("dark.off.") }
            .map { String($0.dropFirst(9)) }
    }

    private static func siteKey(_ host: String) -> String {
        "dark.off." + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    // MARK: The page

    /// Read from disk the first time it's needed, so never with the setting off.
    static let script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "force-dark", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Before the page's first paint, in roko's own world: its Content
        // Security Policy can't refuse it and the page can't see it.
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: PageWatch.world)
    }()

    /// The web view itself, before a page on `host` is asked for. A site with
    /// a dark mode is told to use it, and nothing white shows before the first
    /// paint: without an opaque white canvas the dark behind shows through.
    static func dress(_ webView: WKWebView, for host: String?) {
        let on = applies(to: host)
        guard on || !webView.isOpaque else { return }
        webView.overrideUserInterfaceStyle = on ? .dark : .unspecified
        webView.isOpaque = !on
        webView.backgroundColor = on ? canvas : nil
        webView.scrollView.backgroundColor = on ? canvas : nil
    }

    /// Back to the page's own colours while it becomes a PDF, and on again.
    static func pause(_ webView: WKWebView, _ paused: Bool) async {
        _ = try? await webView.callAsyncJavaScript("window.__rokoDark && window.__rokoDark(paused)",
                                                   arguments: ["paused": paused], in: nil, contentWorld: PageWatch.world)
    }
}
