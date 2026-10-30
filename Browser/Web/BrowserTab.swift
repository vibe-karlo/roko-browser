import UIKit
import WebKit

@MainActor
protocol BrowserTabDelegate: AnyObject {
    func tab(_ tab: BrowserTab, didFinishLoading url: URL, title: String)
    func tab(_ tab: BrowserTab, wantsNewTabWith url: URL)
    /// The same page reloaded again and again, as people do when a page doesn't work.
    func tabKeepsReloading(_ tab: BrowserTab)
    /// A short message for the person, about something that happened in the tab.
    func tab(_ tab: BrowserTab, says message: String)
    /// A link touched and held: its menu, with the page live in the preview.
    func tab(_ tab: BrowserTab, linkMenuFor url: URL) -> UIContextMenuConfiguration?
    /// The preview was tapped: the page becomes a tab, where it was scrolled to.
    func tabOpensPeek(_ tab: BrowserTab)
    /// The menu went away.
    func tabEndsPeek(_ tab: BrowserTab)
    /// A new tab whose page turned out to be a file: nothing to keep it for.
    func tabOnlyDownloaded(_ tab: BrowserTab)
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
    var loadError: LoadError?
    /// When the page was last reloaded after WebKit gave up on it.
    @ObservationIgnored private var lastCrashReload: Date?
    /// Counts hibernations and wakes, so a hibernation overtaken by either stops.
    @ObservationIgnored private var hibernation = 0
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
    /// Recent reloads of the page on screen (see noteReload).
    @ObservationIgnored fileprivate var reloads: [(url: URL, at: Date)] = []
    /// When the current page was asked for, for the -perf load timings.
    @ObservationIgnored fileprivate var navigationStarted: CFTimeInterval?
    /// Sound or video playing on the page, or paused there (PageWatch).
    var media: Media? {
        didSet { if media?.playing == true { playerDismissed = false } }
    }
    /// The mini player was closed for this tab; it comes back when it plays again.
    var playerDismissed = false
    /// What you've typed into a form here and not sent: the tab isn't put
    /// away while it's there, and it's typed back in if the page crashes.
    @ObservationIgnored private(set) var formDraft: FormDrafts.Draft?
    var hasUnsentForm: Bool { formDraft != nil }
    /// Kept live rather than hibernated: it has something a reload would lose.
    var isBusy: Bool { hasUnsentForm || media?.playing == true }

    struct Media: Equatable {
        var playing: Bool
        var isVideo: Bool
        var title: String
        var artist: String
    }

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
            formDraft = FormDrafts.draft(for: id)
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
        // A hibernation still taking its snapshot is called off: this tab is wanted.
        hibernation += 1
        guard webView == nil else { return }
        let webView = WebViewFactory.make(isPrivate: isPrivate)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        PageWatch.shared.register(webView, for: self)
        self.webView = webView
        isLive = true
        observe(webView)

        let wanted = url
        if let restoreState {
            webView.interactionState = restoreState
            self.restoreState = nil
            // A page that failed to load isn't in WebKit's history: restored,
            // the tab came back blank, loading nothing and failing nothing.
            if let wanted, webView.backForwardList.currentItem?.url != wanted {
                webView.load(URLRequest(url: wanted))
            }
        } else if let url {
            webView.load(URLRequest(url: url))
        }
    }

    func hibernate() async {
        guard let webView else { return }
        hibernation += 1
        let ticket = hibernation
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        keep(try? await webView.takeSnapshot(configuration: configuration))
        // Selected meanwhile (wake), or another hibernation got here first: leave it.
        guard ticket == hibernation, self.webView === webView else { return }
        tearDown(webView)
    }

    /// Closed: the page goes at once, with no picture taken of it.
    func close() {
        hibernation += 1
        if let webView { tearDown(webView) }
        discardSnapshot()
    }

    private func tearDown(_ webView: WKWebView) {
        restoreState = webView.interactionState as? Data
        observations.removeAll()
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
        isLive = false
        media = nil
    }

    // MARK: Forms

    /// From the page: what's typed into its forms now. Empty once it's sent.
    func noteForm(_ fields: [String: String], worthKeeping: Bool) {
        guard let url = webView?.url ?? url else { return }
        formDraft = worthKeeping && !fields.isEmpty ? FormDrafts.Draft(url: url, fields: fields, savedAt: .now) : nil
        if !isPrivate { FormDrafts.set(formDraft, for: id) }
    }

    /// A page that loaded again (after a crash, a relaunch, a reload) gets
    /// back what you'd typed into it, in fields that are empty again.
    fileprivate func restoreForm(in webView: WKWebView) {
        guard let draft = formDraft, let url = webView.url, Self.samePage(draft.url, url) else { return }
        Task {
            // Pages often build their forms a moment after they load.
            try? await Task.sleep(for: .milliseconds(700))
            let restored = await PageWatch.call(webView, "restore", ["fields": draft.fields]) as? Int ?? 0
            if restored > 0 { delegate?.tab(self, says: "Brought back what you typed") }
        }
    }

    /// Another page: a draft for the one before stays behind.
    fileprivate func leaveForm(for url: URL?) {
        guard let draft = formDraft, let url, !Self.samePage(draft.url, url) else { return }
        formDraft = nil
        if !isPrivate { FormDrafts.set(nil, for: id) }
    }

    private static func samePage(_ a: URL, _ b: URL) -> Bool {
        func page(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return page(a) == page(b)
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

extension BrowserTab {
    /// A third reload of the same page within 45 seconds: it probably isn't
    /// working. (Two in two minutes was just someone following a live blog.)
    fileprivate func noteReload(of url: URL) {
        let now = Date.now
        reloads = reloads.filter { $0.url == url && now.timeIntervalSince($0.at) < 45 }
        reloads.append((url, now))
        if reloads.count == 3 { delegate?.tabKeepsReloading(self) }
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return (.cancel, preferences)
        }

        if !["http", "https", "about", "blob", "data"].contains(scheme) {
            // tel:, mailto:, maps, App Store links: hand off to the system.
            await openOutside(url, tapped: navigationAction.navigationType == .linkActivated, in: webView)
            return (.cancel, preferences)
        }
        // Open links in apps set to Always: a link you tap to another site
        // whose app you have opens there, as in Safari.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
           !AppLinks.sameSite(webView.url, url), AppLinks.Mode.current == .always,
           AppLinks.installedApp(for: url) != nil, await AppLinks.open(url) {
            return (.cancel, preferences)
        }
        // A link with download, or a blob a page saves: a file, not a page.
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .reload {
            noteReload(of: url)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            let asked = CACurrentMediaTime()
            navigationStarted = asked
            // Instant once the lists are loaded; on a fresh install it holds the
            // first page until blocking is ready rather than loading it bare,
            // for three seconds at most.
            await ContentBlocker.shared.prepare(within: .seconds(3))
            ContentBlocker.shared.configure(webView.configuration.userContentController, for: url.host())
            perf("policy", url, since: asked)
        }
        preferences.preferredContentMode = wantsDesktopSite ? .desktop : .mobile
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }

    /// With -perf: milliseconds from asking for a page to each step of loading it.
    fileprivate func perf(_ step: String, _ url: URL?, since start: CFTimeInterval? = nil) {
        guard LaunchClock.isEnabled, let start = start ?? navigationStarted else { return }
        print(String(format: "NAV %@ %@ %.0fms", step, url?.host() ?? "-", (CACurrentMediaTime() - start) * 1000))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        perf("commit", webView.url)
        media = nil
        leaveForm(for: webView.url)
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
        perf("finish", webView.url)
        if LaunchClock.isEnabled {
            let host = webView.url?.host() ?? "-"
            webView.evaluateJavaScript("""
                (() => { const n = performance.getEntriesByType('navigation')[0] || {};
                  const p = performance.getEntriesByType('paint').find(e => e.name == 'first-contentful-paint');
                  return [Math.round(n.responseStart || 0), Math.round(p ? p.startTime : 0)].join(' '); })()
                """) { result, _ in print("NAV page \(host) firstByte/firstPaint \(result ?? "-") ms") }
        }
        samplePageColors()
        restoreForm(in: webView)
        if let translation {
            Task { await PageTranslator.shared.translate(webView, to: translation) }
        }
        guard let url = webView.url else { return }
        delegate?.tab(self, didFinishLoading: url, title: webView.title ?? "")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        perf("fail \(error.code)", webView.url)
        // Cancelled loads (a new navigation replaced this one) aren't failures.
        guard error.code != NSURLErrorCancelled, error.code != 102 else { return }
        loadError = LoadError(error)
    }

    /// Failed after it had started drawing: the connection dropped mid-page.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        perf("fail late \(error.code)", webView.url)
        // Cancelled (a new page asked for), or a frame WebKit stopped for a
        // download or a hand-off to another app: not failures.
        guard error.code != NSURLErrorCancelled, error.code != 102 else { return }
        loadError = LoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaimed the page's memory; reloading brings it back. Once a
        // minute at most: a page that brings WebKit down every time would
        // otherwise reload forever and drain the battery.
        if let last = lastCrashReload, Date.now.timeIntervalSince(last) < 60 {
            loadError = LoadError(kind: .crashed, host: webView.url?.host())
            return
        }
        lastCrashReload = .now
        webView.reload()
    }

    /// Touch and hold a link: roko's menu over the page itself, live and
    /// scrollable, as Lens does. Anything else (an image, text) gets WebKit's.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        guard Preferences.linkPeek, let url = elementInfo.linkURL, url.scheme == "https" || url.scheme == "http" else {
            return completionHandler(nil)
        }
        completionHandler(delegate?.tab(self, linkMenuFor: url))
    }

    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard elementInfo.linkURL != nil, Preferences.linkPeek else { return }
        animator.preferredCommitStyle = .pop
        animator.addCompletion { [weak self] in
            guard let self else { return }
            self.delegate?.tabOpensPeek(self)
        }
    }

    func webView(_ webView: WKWebView, contextMenuDidEndForElement elementInfo: WKContextMenuElementInfo) {
        delegate?.tabEndsPeek(self)
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

/// Why a page didn't load, in the terms that decide what to do next.
struct LoadError: Equatable {
    enum Kind {
        /// No connection at all: it loads by itself once there is one.
        case offline
        /// No such site: the address is probably wrong.
        case notFound
        /// The site is there but didn't answer, or took too long.
        case notAnswering, slow
        /// Its certificate is wrong: going on isn't offered.
        case unsafe
        /// WebKit gave up on the page more than once.
        case crashed
        case other
    }

    let kind: Kind
    let host: String?
    var detail: String = ""

    init(kind: Kind, host: String?, detail: String = "") {
        self.kind = kind
        self.host = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        self.detail = detail
    }

    init(_ error: NSError) {
        let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let kind: Kind = switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff: .offline
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: .notFound
        case NSURLErrorCannotConnectToHost, NSURLErrorBadServerResponse: .notAnswering
        case NSURLErrorTimedOut: .slow
        case NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected: .unsafe
        default: .other
        }
        self.init(kind: kind, host: failing?.host(), detail: error.localizedDescription)
    }
}
