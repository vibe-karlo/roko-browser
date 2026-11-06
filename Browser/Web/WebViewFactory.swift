import UIKit
import WebKit
#if DEBUG
import Network
#endif

enum WebViewFactory {
    /// One web view built ahead of time, so the first page skips WebKit's setup cost.
    private static var prewarmed: WKWebView?
    private static var privateStore = WKWebsiteDataStore.nonPersistent()

    /// The last private tab closed: its cookies and storage go with it, so the
    /// next private tab starts signed out of everything.
    static func endPrivateSession() {
        privateStore = .nonPersistent()
    }

    static func prewarm() {
        guard prewarmed == nil else { return }
        prewarmed = build(isPrivate: false)
    }

    /// Under memory pressure the spare web view goes; the next tab builds its own.
    static func dropPrewarmed() {
        prewarmed = nil
    }

    static func make(isPrivate: Bool) -> WKWebView {
        if !isPrivate, let webView = prewarmed {
            prewarmed = nil
            // The next tab's is built once a page has finished loading
            // (BrowserModel), not a second from now, in the middle of this one.
            return webView
        }
        return build(isPrivate: isPrivate)
    }

    /// For reading a page out of sight (Notify Me): with your cookies, as the
    /// page would be for you, and without taking the spare.
    static func makeOffscreen() -> WKWebView {
        build(isPrivate: false, offscreen: true)
    }

    private static func build(isPrivate: Bool, offscreen: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? privateStore : .default()
        #if DEBUG
        // Scripts/compare/proxy.py sees which servers a page reaches: -proxy 127.0.0.1:8766
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-proxy"), index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: ":").map(String.init)
            configuration.websiteDataStore.proxyConfigurations = [
                ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(parts[0]), port: .init(parts[1])!))
            ]
        }
        #endif
        configuration.allowsInlineMediaPlayback = true
        // Video in its own window while you do something else (the mini player's button).
        configuration.allowsPictureInPictureMediaPlayback = true
        // Autoplaying video is the biggest battery and data drain on mobile.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        // Tabs that aren't on screen freeze completely (no JavaScript, no layout)
        // instead of being merely throttled, so they can't steal time from the
        // page you're looking at. Media playback and loads are exempt.
        // A view never in a window counts as inactive from the start: suspended,
        // its page's scripts would never fill the page in for Notify Me.
        configuration.preferences.inactiveSchedulingPolicy = offscreen ? .throttle : .suspend
        // No scanning page text for phone numbers, dates and addresses.
        configuration.dataDetectorTypes = []

        let controller = WKUserContentController()
        ContentBlocker.shared.install(in: controller)
        PageWatch.shared.install(in: controller)
        configuration.userContentController = controller

        return finished(EdgeToEdgeWebView(frame: .zero, configuration: configuration))
    }

    /// A window a page opened (sign-in, payment): WebKit's configuration, which
    /// ties it to the page that opened it, in the same kind of web view.
    static func makeWindow(configuration: WKWebViewConfiguration) -> WKWebView {
        finished(EdgeToEdgeWebView(frame: .zero, configuration: configuration))
    }

    private static func finished(_ webView: WKWebView) -> WKWebView {
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // Opaque, so WebKit paints the page's own default canvas: white for
        // sites without dark mode, dark for sites that ask for it. A clear web
        // view let the app's dark backdrop show behind black text.
        webView.isOpaque = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }
}

extension WKWebView {
    var isPreloading: Bool { (self as? EdgeToEdgeWebView)?.preloading == true }
}

/// Pages run all the way to the bottom edge, as in Safari's full-screen mode.
/// Left alone, the web view keeps a scroll gap the height of the home indicator
/// below every page, painted in the page background: a light strip under a
/// dark footer. The bar's own strip is handled by obscuredContentInsets.
final class EdgeToEdgeWebView: WKWebView {
    /// An open iPhone Duo in landscape: pages run under the clock's strip too,
    /// and showing or hiding the clock never changes their width.
    static var fillsSides = false

    /// The launcher's top hit, loading behind everything before Go. In the window
    /// but not to be seen, so it asks nothing of anyone and saves nothing.
    var preloading = false

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = 0
        if Self.fillsSides {
            insets.left = 0
            insets.right = 0
        }
        return insets
    }

    /// Ask roko, first in the menu over text you select: Browse for Me on
    /// those words, as Arc Search does. Set by BrowserModel.
    static var ask: ((String) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard Self.ask != nil else { return }
        let action = UIAction(title: "Ask roko", image: UIImage(named: "phosphor/browse")) { [weak self] _ in
            self?.evaluateJavaScript("window.getSelection().toString()", in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result,
                      let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                Self.ask?(String(text.prefix(300)))
            }
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [action]), atStartOfMenu: .root)
    }
}
