import UIKit
import WebKit

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
            // The next tab gets one too, built once this one's page is under way.
            Task {
                try? await Task.sleep(for: .seconds(1))
                prewarm()
            }
            return webView
        }
        return build(isPrivate: isPrivate)
    }

    /// For reading a page out of sight (Notify Me): with your cookies, as the
    /// page would be for you, and without taking the spare.
    static func makeOffscreen() -> WKWebView {
        build(isPrivate: false)
    }

    private static func build(isPrivate: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? privateStore : .default()
        configuration.allowsInlineMediaPlayback = true
        // Autoplaying video is the biggest battery and data drain on mobile.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        // Tabs that aren't on screen freeze completely (no JavaScript, no layout)
        // instead of being merely throttled, so they can't steal time from the
        // page you're looking at. Media playback and loads are exempt.
        configuration.preferences.inactiveSchedulingPolicy = .suspend
        // No scanning page text for phone numbers, dates and addresses.
        configuration.dataDetectorTypes = []

        let controller = WKUserContentController()
        ContentBlocker.shared.install(in: controller)
        configuration.userContentController = controller

        let webView = EdgeToEdgeWebView(frame: .zero, configuration: configuration)
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

/// Pages run all the way to the bottom edge, as in Safari's full-screen mode.
/// Left alone, the web view keeps a scroll gap the height of the home indicator
/// below every page, painted in the page background: a light strip under a
/// dark footer. The bar's own strip is handled by obscuredContentInsets.
final class EdgeToEdgeWebView: WKWebView {
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = 0
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
