import UIKit
import WebKit

enum WebViewFactory {
    /// One web view built ahead of time, so the first page skips WebKit's setup cost.
    private static var prewarmed: WKWebView?
    private static let privateStore = WKWebsiteDataStore.nonPersistent()

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
        // No rubber-band zoom below the page's size: pinching in shrinks the
        // whole page toward a summary instead (see WebViewHost).
        webView.scrollView.bouncesZoom = false
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
}
