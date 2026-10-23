import UIKit
import WebKit

@MainActor
protocol BrowserTabDelegate: AnyObject {
    func tab(_ tab: BrowserTab, didFinishLoading url: URL, title: String)
    func tab(_ tab: BrowserTab, wantsNewTabWith url: URL)
}

/// One tab. Its web view exists only while the tab is "live"; a hibernated tab
/// keeps a snapshot and its back/forward state and costs almost no memory.
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    var url: URL?
    var title: String
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var loadError: String?
    /// Asks sites for their desktop layout; set from the page menu.
    private(set) var wantsDesktopSite = false
    /// The language this tab's pages are translated into, if any. Stays on for
    /// the pages you open next in the tab, until you show the original.
    private(set) var translation: TranslationTarget?
    var lastActive: Date
    private(set) var snapshot: UIImage?
    private(set) var isLive = false
    /// The colour the page wants around its top edge: its theme-color, else its
    /// background. The status bar band takes it, as in Safari.
    private(set) var topColor: UIColor?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var restoreState: Data?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored weak var delegate: BrowserTabDelegate?

    init(id: UUID = UUID(), url: URL?, title: String = "", isPrivate: Bool = false,
         lastActive: Date = .now, restoreState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.isPrivate = isPrivate
        self.lastActive = lastActive
        self.restoreState = restoreState
        super.init()
        if !isPrivate {
            snapshot = UIImage(contentsOfFile: snapshotFile.path)
        }
    }

    // MARK: Snapshot cache

    private static let snapshotDirectory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var snapshotFile: URL {
        Self.snapshotDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Shows the image now and writes it to disk in the background, so a
    /// restored tab still has its picture in the tab switcher.
    private func keep(_ image: UIImage?) {
        guard let image else { return }
        snapshot = image
        guard !isPrivate else { return }
        let file = snapshotFile
        // Compressing a JPEG takes a few milliseconds: never on the main thread.
        Task.detached(priority: .utility) {
            try? image.jpegData(compressionQuality: 0.7)?.write(to: file)
        }
    }

    /// Deletes saved pictures of tabs that no longer exist (closed while the
    /// app was gone, or archived). Runs in the background after launch.
    nonisolated static func pruneSnapshots(keeping ids: Set<UUID>) async {
        let directory = await snapshotDirectory
        await Task.detached(priority: .background) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where !ids.contains(where: { file.lastPathComponent == "\($0.uuidString).jpg" }) {
                try? FileManager.default.removeItem(at: file)
            }
        }.value
    }

    /// Swaps the decoded picture (about 10 MB at full resolution) for one read
    /// lazily from disk, which iOS can drop and reload as needed.
    func releaseSnapshotMemory() {
        guard !isPrivate, snapshot != nil, FileManager.default.fileExists(atPath: snapshotFile.path),
              let light = UIImage(contentsOfFile: snapshotFile.path) else { return }
        snapshot = light
    }

    func discardSnapshot() {
        try? FileManager.default.removeItem(at: snapshotFile)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.displayHost ?? "New tab"
    }

    /// Back/forward history in WebKit's own format, for saving tabs across launches.
    var interactionState: Data? {
        (webView?.interactionState as? Data) ?? restoreState
    }

    // MARK: Lifecycle

    func wake() {
        guard webView == nil else { return }
        let webView = WebViewFactory.make(isPrivate: isPrivate)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        isLive = true
        observe(webView)

        if let restoreState {
            webView.interactionState = restoreState
            self.restoreState = nil
        } else if let url {
            webView.load(URLRequest(url: url))
        }
    }

    func hibernate() async {
        guard let webView else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        keep(try? await webView.takeSnapshot(configuration: configuration))
        restoreState = webView.interactionState as? Data
        observations.removeAll()
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
        isLive = false
    }

    /// Refreshes the card image used in the tab overview.
    func captureSnapshot() async {
        guard let webView, webView.window != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        keep(try? await webView.takeSnapshot(configuration: configuration))
    }

    func translate(to target: TranslationTarget?) {
        let previous = translation
        translation = target
        guard let webView else { return }
        Task {
            if let target {
                // Switching languages: back to the original text first.
                if previous != nil { await PageTranslator.shared.restore(webView) }
                await PageTranslator.shared.translate(webView, to: target)
            } else {
                await PageTranslator.shared.restore(webView)
            }
        }
    }

    /// What's on screen right now, at full resolution, for the page-to-card
    /// animation. Not cached: it's used once.
    func viewportSnapshot() async -> UIImage? {
        guard let webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        // The whole view, the strip under the bar included: by default WebKit
        // leaves out the obscured inset, and the card growing back into the
        // page would then show a gap there until the page took over.
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    func setDesktopSite(_ desktop: Bool) {
        wantsDesktopSite = desktop
        // A fresh load rather than reload(), so the new content mode is asked for.
        if let url = webView?.url ?? url { webView?.load(URLRequest(url: url)) }
    }

    /// Steps the page zoom for this site and remembers it.
    func stepZoom(_ direction: Int) {
        guard let webView else { return }
        let level = PageZoom.step(from: webView.pageZoom, direction: direction)
        webView.pageZoom = level
        PageZoom.remember(level, for: webView.url?.host())
        zoomLevel = level
    }

    private(set) var zoomLevel: CGFloat = 1

    func load(_ url: URL) {
        self.url = url
        loadError = nil
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            restoreState = nil
            wake()
        }
    }

    // MARK: Observation

    private func observe(_ webView: WKWebView) {
        // KVO on WKWebView fires on the main thread.
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.url = webView.url ?? self?.url }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    if let title = webView.title, !title.isEmpty { self?.title = title }
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.themeColor, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.updateTopColor(webView) }
            },
            webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    // Our own footer colour isn't the page's background; keep the real one.
                    guard let self, !self.showsFooterColor else { return }
                    self.pageBackground = webView.underPageBackgroundColor
                    self.updateTopColor(webView)
                }
            },
        ]
        pageBackground = webView.underPageBackgroundColor
    }

    /// The background of a navigation bar the page pins to the top, if it has one.
    @ObservationIgnored private var pinnedHeaderColor: UIColor?
    /// The colour at the very bottom of the page: usually its footer.
    @ObservationIgnored private var footerColor: UIColor?
    /// The page's own background, as WebKit reports it.
    @ObservationIgnored private var pageBackground: UIColor? {
        didSet { updateBottomColor() }
    }
    /// What shows behind the page below the status bar: the footer's colour
    /// near the end of a page, the page's own background elsewhere.
    private(set) var bottomColor: UIColor?

    private func updateBottomColor() {
        let color = showsFooterColor ? (footerColor ?? pageBackground) : pageBackground
        if color != bottomColor { bottomColor = color }
    }
    /// Whether the strip past the page's end currently shows the footer colour.
    @ObservationIgnored private var showsFooterColor = false

    /// Reads the two colours that meet the screen edges. Top: a header that is
    /// fixed or sticky and spans the width; its first solid background, from the
    /// point up through its parents. Bottom, only near the end of the page: the
    /// solid background painted at the screen's bottom-left corner, under anything
    /// the site pins there. Two hit tests and a few style reads, in an isolated
    /// world the page can't see.
    private static let pageColorsScript = """
        (() => {
          const solid = (el) => {
            const parts = getComputedStyle(el).backgroundColor.match(/[\\d.]+/g);
            return parts && (parts.length < 4 || +parts[3] > 0.9) ? parts.slice(0, 3).join(",") : null;
          };
          let top = null, color = null;
          for (let el = document.elementFromPoint(innerWidth / 2, 2); el && el !== document.documentElement; el = el.parentElement) {
            color = color || solid(el);
            const position = getComputedStyle(el).position;
            if (position === "fixed" || position === "sticky") {
              const box = el.getBoundingClientRect();
              if (box.top <= 2 && box.width >= innerWidth * 0.9) { top = color; break; }
            }
          }
          // Only near the end: what's on screen then is the footer.
          let bottom = null;
          if (scrollY + innerHeight * 1.5 >= document.documentElement.scrollHeight) {
            const pinned = (el) => { for (; el; el = el.parentElement) { if (getComputedStyle(el).position === "fixed") return true; } return false; };
            // Top to bottom in paint order: the first solid background is what shows there.
            for (const el of document.elementsFromPoint(2, innerHeight - 2)) {
              if (pinned(el)) continue;
              bottom = solid(el);
              if (bottom) break;
            }
          }
          return { top, bottom };
        })()
        """

    /// Re-reads both edge colours; called when a page settles or stops scrolling.
    func samplePageColors() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.pageColorsScript, in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self, let webView, case .success(let value) = result, let colors = value as? [String: Any] else { return }
            let top = Self.color(colors["top"]), bottom = Self.color(colors["bottom"])
            if top != pinnedHeaderColor {
                pinnedHeaderColor = top
                updateTopColor(webView)
            }
            // Away from the end the script reports nothing: keep what was read there.
            if let bottom, bottom != footerColor {
                footerColor = bottom
                if showsFooterColor { webView.underPageBackgroundColor = bottom }
                updateBottomColor()
            }
        }
    }

    private static func color(_ value: Any?) -> UIColor? {
        guard let rgb = value as? String else { return nil }
        let parts = rgb.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    /// Near the end of a page, the strip past its last pixel (above the home
    /// indicator) takes the footer's colour instead of the page background,
    /// as the status bar takes the header's. Near the top it goes back, so a
    /// pull to refresh still shows the page's own colour.
    func showFooterColor(_ show: Bool) {
        guard show != showsFooterColor, let webView else { return }
        showsFooterColor = show
        webView.underPageBackgroundColor = show ? footerColor : nil
        updateBottomColor()
    }

    private func updateTopColor(_ webView: WKWebView) {
        // A sticky navigation bar wins: it is literally what touches the status bar.
        let color = pinnedHeaderColor ?? webView.themeColor ?? pageBackground
        // Ignore see-through colours; they'd show the app's own backdrop instead.
        var alpha: CGFloat = 0
        color?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        let usable = alpha > 0.9 ? color : nil
        if usable != topColor { topColor = usable }
    }
}

// MARK: - Navigation

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return (.cancel, preferences)
        }

        if !["http", "https", "about", "blob", "data"].contains(scheme) {
            // tel:, mailto:, maps, App Store links: hand off to the system.
            await UIApplication.shared.open(url)
            return (.cancel, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            // Instant once the lists are loaded; on a fresh install it holds the
            // first page until blocking is ready rather than loading it bare.
            await ContentBlocker.shared.prepare()
            ContentBlocker.shared.configure(webView.configuration.userContentController, for: url.host())
        }
        preferences.preferredContentMode = wantsDesktopSite ? .desktop : .mobile
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Each site keeps the zoom you last chose for it.
        let zoom = PageZoom.level(for: webView.url?.host())
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        zoomLevel = zoom

        // A new page: forget the old colours, and read this one's once it has drawn.
        pinnedHeaderColor = nil
        footerColor = nil
        showFooterColor(false)
        updateTopColor(webView)
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            samplePageColors()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        samplePageColors()
        if let translation {
            Task { await PageTranslator.shared.translate(webView, to: translation) }
        }
        guard let url = webView.url else { return }
        delegate?.tab(self, didFinishLoading: url, title: webView.title ?? "")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        // Cancelled loads (a new navigation replaced this one) aren't failures.
        guard error.code != NSURLErrorCancelled, error.code != 102 else { return }
        loadError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaimed the page's memory; reloading brings it back.
        webView.reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" and window.open: open as a real tab instead of a popup.
        if let url = navigationAction.request.url {
            delegate?.tab(self, wantsNewTabWith: url)
        }
        return nil
    }
}
