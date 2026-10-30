import UIKit
import WebKit

/// roko's own script on every page (page-watch.js): forms you've typed into,
/// sound or video playing, and whether a sideways swipe belongs to the page.
/// It runs in a script world of its own, so the page can't see or fake it.
@MainActor
final class PageWatch: NSObject, WKScriptMessageHandler {
    static let shared = PageWatch()
    static let world = WKContentWorld.world(name: "roko.page")
    static let handlerName = "rokoPage"

    static let script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "page-watch", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }()

    /// Which tab each web view belongs to.
    private let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    func register(_ webView: WKWebView, for tab: BrowserTab) {
        tabs.setObject(tab, forKey: webView)
    }

    /// Once per web view: the handler stays when the blocker swaps its scripts.
    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let tab = tabs.object(forKey: webView),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "form":
            let fields = body["fields"] as? [String: String] ?? [:]
            // A few letters in a field aren't a form worth keeping a tab for.
            let typed = body["typed"] as? Int ?? 0
            tab.noteForm(fields, worthKeeping: typed >= 12 || fields.count >= 3)
        case "formSent":
            tab.noteForm([:], worthKeeping: false)
        case "media":
            tab.media = BrowserTab.Media(playing: body["playing"] as? Bool ?? false,
                                         isVideo: body["video"] as? Bool ?? false,
                                         title: body["title"] as? String ?? "",
                                         artist: body["artist"] as? String ?? "",
                                         artwork: (body["artwork"] as? String).flatMap(URL.init(string:)),
                                         time: body["time"] as? Double ?? 0,
                                         duration: body["duration"] as? Double ?? 0,
                                         isFloating: body["floating"] as? Bool ?? false)
        case "mediaGone":
            tab.media = nil
        default:
            break
        }
    }

    /// Calls one of the page's roko functions (window.__rokoPage).
    @discardableResult
    static func call(_ webView: WKWebView?, _ function: String,
                     _ arguments: KeyValuePairs<String, Any> = [:]) async -> Any? {
        guard let webView else { return nil }
        // In the order given: they're the function's parameters, by position.
        let names = arguments.map(\.key)
        return try? await webView.callAsyncJavaScript(
            "return window.__rokoPage ? window.__rokoPage.\(function)(\(names.joined(separator: ","))) : null",
            arguments: Dictionary(uniqueKeysWithValues: arguments.map { ($0.key, $0.value) }), in: nil, contentWorld: world)
    }
}
