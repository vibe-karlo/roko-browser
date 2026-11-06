import SwiftData
import SwiftUI
import WebKit

/// The whole browser's state: tabs, which one is showing, and which panel is open.
@Observable
final class BrowserModel {
    enum Panel: Equatable {
        case none, command, tabs, tools, settings, notifyMe, todos, today, shopping, readLater, feed, downloads
    }

    enum CommandMode {
        case newTab, currentTab, privateTab
    }

    /// What the launcher is for, from the screen it was opened on.
    enum LauncherContext: Equatable {
        /// Addresses, searches and answers: the browser's own.
        case web
        /// To-do: what's typed is a new to-do.
        case todo
        /// Browse for Me: what's typed is a follow-up.
        case followUp
        /// A summary: what's typed is a question about the page.
        case aboutPage
        /// Summarize all: what's typed is a question about the saved pages.
        case aboutSaved
    }

    /// Live web views kept in memory; older tabs hibernate to a snapshot.
    static let liveTabLimit = 3

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedID: BrowserTab.ID?
    var panel: Panel = .none {
        // Back from the to-do list or the bar (a to-do added there): what's due may have changed.
        didSet {
            if [.todos, .command].contains(oldValue), panel != oldValue { refreshLive() }
            if panel == .command { showsLaunchField = false }
            // On an open Duo Read Later is half the screen, not a panel over it: the page and its controls stay live.
            if panel == .readLater, uprightFoldOpen, selectedTab != nil, split == nil {
                readLaterBeside = true
                panel = .none
            }
        }
    }
    var commandPrefill = ""
    var commandMode: CommandMode = .newTab
    var launcherContext: LauncherContext = .web
    /// The screen the launcher was opened over, shown again when it closes.
    var launcherReturn: Panel = .none
    /// Where the bar's capsule that opened the launcher is on screen: its field grows out of it.
    var launcherOrigin: CGRect = .zero
    /// The launcher is open or opening (the bar steps back meanwhile).
    var launcherShown = false
    /// Its rows are in (after the field has landed).
    var launcherRows = false
    /// + is held: the launcher is listening.
    private(set) var voiceListening = false
    /// What was said, once + is let go, for the launcher to take as typed.
    var voiceResult: String?
    var isBarCollapsed = false {
        didSet {
            if isBarCollapsed { showsLaunchField = false }
            if isBarCollapsed != oldValue { bandOpenedOverBar = false }
        }
    }
    /// Just launched: the bar's capsule stands open as a search field, as Apple
    /// asks of a browser, until the page is scrolled or the bar is opened.
    var showsLaunchField = true
    /// Hide Distracting Items is on: how many things were hidden so far, or nil.
    private(set) var hidingItems: Int?
    @ObservationIgnored private let picker = HiddenItemsPicker()
    var summary: SummaryModel? {
        // Closed before it's finished: stop there, as Browse for Me does.
        didSet { if oldValue !== summary { oldValue?.cancel() } }
    }
    /// True while the summary's card stands in for the page, which hides
    /// underneath so the two never show at once.
    var summaryCoversPage = false
    /// A pull has the page turning into the summary's card: the bar steps aside.
    var pageBecomingSummary = false
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The site roko is offering to allow cookies on (see tabKeepsReloading).
    private(set) var cookieOffer: String?
    @ObservationIgnored private var cookieOfferTask: Task<Void, Never>?
    /// Offered once per site while roko is open.
    @ObservationIgnored private var cookieOffersMade = Set<String>()
    /// The page on screen has an app on this iPhone: offered above the bar,
    /// once per site while roko is open (Settings → Tabs → Open links in apps).
    private(set) var appOffer: (app: AppLinks.App, url: URL)?
    @ObservationIgnored private var appOfferTask: Task<Void, Never>?
    @ObservationIgnored private var appOffersMade = Set<String>()

    /// A link copied a moment ago, offered above the bar on opening roko.
    private(set) var copiedLinkOffer = false
    /// The link itself, when roko may read it; otherwise the offer pastes it.
    private(set) var copiedLinkURL: URL?
    @ObservationIgnored private var copiedLinkTask: Task<Void, Never>?

    /// Opening roko (or coming back to it) with a link just copied, here or
    /// on a Mac: offer it above the bar, once per copy. After that it waits in
    /// the address bar for a few minutes.
    func offerCopiedLinkIfFresh() {
        // Only when it can be seen: checking marks this copy as offered.
        guard panel == .none, summary == nil, browseForMe == nil else { return }
        Task {
            guard await CopiedLink.shouldOfferAboveBar() else { return }
            let url = await CopiedLink.peek()
            // Already on screen, not a link after all, or offered before: nothing to offer.
            if LaunchClock.isEnabled { print("CLIP offer \(CopiedLink.isRuledOut ? "ruled out" : url?.absoluteString ?? "paste button")") }
            if CopiedLink.isRuledOut { return }
            // Only a link it can show: the Paste button alone, above the bar,
            // is an empty capsule when iOS has nothing it will paste. It's
            // still a row in the address bar.
            guard let url, !isCurrentPage(url) else { return }
            CopiedLink.remember(url)
            copiedLinkURL = url
            copiedLinkOffer = true
            copiedLinkTask?.cancel()
            copiedLinkTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { copiedLinkOffer = false }
            }
        }
    }

    /// Read on without it: put away, not offered again for this copy.
    func dismissCopiedLink() {
        guard copiedLinkOffer else { return }
        CopiedLink.took()
        copiedLinkOffer = false
        copiedLinkTask?.cancel()
    }

    func openCopiedLink(_ url: URL) {
        CopiedLink.took()
        CopiedLink.remember(url)
        copiedLinkOffer = false
        copiedLinkTask?.cancel()
        open(url, inNewTab: true)
    }
    var browseForMe: BrowseSession? {
        // An answer that's closed or replaced stops working on the spot:
        // nobody will read it, so it shouldn't keep searching or spending tokens.
        didSet {
            if oldValue !== browseForMe { oldValue?.cancel() }
            if browseForMe == nil { pageBeside = false }
        }
    }
    /// An open iPhone Duo in landscape: the fold runs top to bottom.
    var uprightFoldOpen = false {
        didSet {
            guard oldValue != uprightFoldOpen else { return }
            EdgeToEdgeWebView.fillsSides = uprightFoldOpen
            for tab in tabs { tab.webView?.setNeedsLayout() }
        }
    }
    /// The tab on screen was opened from the answer or the list beside it, and closes back to them.
    var pageBeside = false
    /// Read Later has the leading half of an open Duo.
    var readLaterBeside = false {
        didSet {
            guard !readLaterBeside else { return }
            finishSavedBeside()
            pageBeside = false
        }
    }
    /// The saved page open beside the list. It keeps its place there until
    /// another is opened or the list closes, and only then counts as read.
    private(set) var savedBeside: UUID?
    /// Where Saved was left, for the list to take up as it opens.
    var savedPlaceToRestore: SavedPlace?
    /// One of roko's own screens has the leading half of an open Duo, the page the trailing one.
    var screenBeside: Bool {
        uprightFoldOpen && selectedTab != nil && split == nil
            && (pageBeside && browseForMe != nil || readLaterBeside || summary != nil)
    }
    /// Which half of an open Duo the bar has to keep to, when it does: the page's
    /// side of what stands beside it, or under the page it works in a split.
    var barSide: HorizontalEdge? {
        if screenBeside { return .trailing }
        guard uprightFoldOpen, split != nil || splitPickingTop != nil else { return nil }
        return split?.bottom == selectedID ? .trailing : .leading
    }
    var cook: CookModel?
    var reader: ReaderModel?
    /// Summarize all, over Read Later.
    var digest: DigestModel? {
        didSet { if oldValue !== digest { oldValue?.cancel() } }
    }

    @ObservationIgnored private var context: ModelContext?
    /// The bar's history, in memory (see HistoryIndex).
    @ObservationIgnored let historyIndex = HistoryIndex()
    /// The open tabs' own context, signed "tabs": their saves are the one thing
    /// that writes the device store steadily, and the change history they leave
    /// can be pruned by that name (Store.pruneDeviceHistory).
    @ObservationIgnored private var tabContext: ModelContext?

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }

    func tab(_ id: BrowserTab.ID) -> BrowserTab? { tabs.first { $0.id == id } }

    // MARK: Split View

    /// Two tabs on screen at once, one above the other. The selected tab is
    /// whichever half was touched last.
    struct Split: Equatable {
        var top: BrowserTab.ID
        var bottom: BrowserTab.ID

        func contains(_ id: BrowserTab.ID?) -> Bool { id == top || id == bottom }
    }

    private(set) var split: Split? {
        // Two pages side by side: back no longer leaves one for the list.
        didSet {
            guard let split else { return }
            tab(split.top)?.savedPlace = nil
            tab(split.bottom)?.savedPlace = nil
        }
    }

    /// The tab whose page meets the status bar: the top half of a split.
    var topTab: BrowserTab? { split.flatMap { tab($0.top) } ?? selectedTab }
    /// How much of the screen the top half has.
    var splitFraction: CGFloat = 0.5

    /// The page on screen and another, split. With no tab given (the page
    /// menu, the bar), the split opens at once with the page on top and a
    /// card below asking which page goes there.
    func startSplit(with other: BrowserTab? = nil) {
        guard let current = selectedTab else { return }
        panel = .none
        guard let partner = other, partner.id != current.id else {
            splitFraction = 0.5
            pendingSplitWith = current.id
            return
        }
        pendingSplitWith = nil
        splitFraction = 0.5
        split = Split(top: current.id, bottom: partner.id)
        partner.wake()
        select(partner)
    }

    /// Split View started with its bottom half still to choose: the tab on top.
    private var pendingSplitWith: BrowserTab.ID?
    /// Split View is waiting for its second page (the card below, and the bar opened from it).
    var isPickingSplit: Bool { splitPickingTop != nil }

    /// To-dos or the shopping list opened during Split View: they take the
    /// second half, beside the page, instead of covering both.
    var splitList: Panel? {
        guard split != nil || isPickingSplit else { return nil }
        for list in [Panel.todos, .shopping] where panel == list || panel == .command && launcherReturn == list {
            return list
        }
        return nil
    }

    /// The page on top while the bottom half is being chosen.
    var splitPickingTop: BrowserTab? {
        guard split == nil, let id = pendingSplitWith else { return nil }
        return tab(id)
    }

    /// The card's search field: the bar, whose page goes below.
    func pickSplitPage() {
        guard let top = splitPickingTop else { return }
        showCommandBar(mode: top.isPrivate ? .privateTab : .newTab)
    }

    /// Back to one tab: the one in use, or the one asked for.
    func endSplit(keeping kept: BrowserTab? = nil) {
        // A list in the second half goes with it, rather than filling the screen.
        if splitList != nil { panel = .none }
        pendingSplitWith = nil
        guard split != nil else { return }
        split = nil
        if let kept, kept.id != selectedID { select(kept) }
    }

    func swapSplit() {
        guard let current = split else { return }
        split = Split(top: current.bottom, bottom: current.top)
    }

    /// The page on screen, offered to your other devices through Handoff
    /// (a Mac's Dock opens it in its default browser). Never a private tab.
    var handoffPage: HandoffPage? {
        guard let tab = selectedTab, !tab.isPrivate, let url = tab.url,
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return HandoffPage(url: url, title: tab.displayTitle)
    }

    struct HandoffPage: Equatable {
        let url: URL
        let title: String
    }

    // MARK: Launch and persistence

    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        let tabContext = ModelContext(context.container)
        tabContext.author = Store.tabsAuthor
        tabContext.autosaveEnabled = false
        self.tabContext = tabContext
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relieveMemory() }
        }
        // Build one web view now so the restored tab takes it, then build the
        // spare for the next new tab once launch has settled, not during it.
        WebViewFactory.prewarm()
        LaunchClock.mark("webViewBuilt")
        restoreTabs()
        LaunchClock.mark("tabsRestored \(tabs.count)")
        // Downloads resume in a live tab's web view.
        Downloads.shared.liveWebViews = { [weak self] in self?.tabs.compactMap(\.webView) ?? [] }
        // The band under the page: parking and what's due, kept current.
        startLiveTicker()
        // Ask roko, over text selected on a page.
        EdgeToEdgeWebView.ask = { [weak self] text in self?.browse(for: text) }
        // YouTube plays on as sound when roko leaves the screen.
        BackgroundPlay.watch { [weak self] in self?.tabs.compactMap(\.webView) ?? [] }
        // A Notify Me notification opens its page.
        NotificationRouter.shared.open = { [weak self] url in self?.handleLink(url) }
        Parking.shared.say = { [weak self] message in self?.showToast(message) }
        // Cookies accepted because a site needs them: say so, once per site.
        ConsentHandler.shared.onAccepted = { [weak self] host, _ in
            self?.showToast("Accepted cookies: \(URL(string: "https://\(host)")?.displayHost ?? host) needs them")
        }
        ContentBlocker.shared.onAdsAllowed = { [weak self] host in
            self?.showToast("Ads allowed: \(URL(string: "https://\(host)")?.displayHost ?? host) shows nothing without them")
        }
        Task {
            await ContentBlocker.shared.prepare()
            LaunchClock.mark("blockerReady")
            // A link that opened roko arrives about now: give it a moment, so the
            // last tab doesn't start loading for nothing.
            try? await Task.sleep(for: .milliseconds(60))
            // Only now start the restored page, so its very first requests are
            // already filtered. Until then its saved snapshot stands in.
            if let tab = selectedTab { select(tab) }
            historyIndex.rebuild(from: context.container)
            // Housekeeping, spread out: each piece is a few to a few dozen
            // milliseconds on the main thread, and all in one go they cost a
            // frame while the first page was still settling.
            try? await Task.sleep(for: .seconds(1.5))
            WebViewFactory.prewarm()
            try? await Task.sleep(for: .seconds(1))
            // Pay the calculator's one-time setup (formatters, unit tables) now,
            // not on the first keystroke.
            _ = Calculator.answer("1 km + 1")
            try? await Task.sleep(for: .seconds(1.5))
            await tidyUp()
        }
        // The bar (and its keyboard) waits for the welcome to finish.
        if tabs.isEmpty, !showsOnboarding { panel = .command }
    }

    /// Launch housekeeping, once things are quiet: pictures of tabs that are
    /// gone, and history older than 90 days, which would otherwise grow forever
    /// and slow every address-bar search.
    private func tidyUp() async {
        await BrowserTab.pruneSnapshots(keeping: Set(tabs.map(\.id)))
        FormDrafts.keep(only: Set(tabs.map(\.id)))
        guard let context else { return }
        let cutoff = Date.now.addingTimeInterval(-90 * 24 * 3600)
        // One by one rather than as a batch: history syncs, and the removal
        // has to reach iCloud like any other change.
        let old = (try? context.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.visitedAt < cutoff }))) ?? []
        old.forEach(context.delete)
        try? context.save()
        Store.pruneDeviceHistory(in: context.container)
        // The merge reads all of history: a frame apart from the prune above.
        try? await Task.sleep(for: .milliseconds(500))
        mergeSyncedDuplicates()
    }

    /// Pages and pins that two devices added before hearing from each other.
    /// At most once an hour: it reads all of history.
    func mergeSyncedDuplicates() {
        guard Store.syncs, let context else { return }
        if let last = lastMerge, Date.now.timeIntervalSince(last) < 3600 { return }
        lastMerge = .now
        Store.mergeDuplicates(in: context)
        historyIndex.rebuild(from: context.container)
    }
    @ObservationIgnored private var lastMerge: Date?

    /// iOS is short of memory: give back what can be rebuilt, before it has to
    /// close roko. The tab on screen is never touched.
    private func relieveMemory() {
        for tab in tabs where tab.id != selectedID {
            // A half-filled form, or sound still playing: worth the memory.
            if tab.isLive, tab.isBusy || split?.contains(tab.id) == true { continue }
            if tab.isLive {
                // Its fresh picture is still being written; the web view is the big saving.
                Task { await tab.hibernate() }
            } else {
                tab.releaseSnapshotMemory()
            }
        }
        BrowserTab.dropThumbnails(except: selectedID)
        WebViewFactory.dropPrewarmed()
        FaviconStore.shared.trimMemory()
    }

    private func restoreTabs() {
        guard let context = tabContext else { return }
        let saved = (try? context.fetch(FetchDescriptor<SavedTab>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let cutoff = Date.now.addingTimeInterval(-ArchivePolicy.current.interval)

        // A tab with a form you hadn't sent stays, however old.
        for record in saved where record.lastActive > cutoff || FormDrafts.draft(for: record.tabID) != nil {
            let tab = BrowserTab(id: record.tabID, url: URL(string: record.url), title: record.title,
                                 lastActive: record.lastActive, restoreState: record.interactionState)
            tab.delegate = self
            tabs.append(tab)
        }
        // Tabs past the archive window simply drop off; they stay findable in History.
        // Selected but not woken: start() wakes it once blocking is ready.
        selectedID = tabs.max(by: { $0.lastActive < $1.lastActive })?.id
    }

    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Saves the open tabs a moment after things settle. Pages often finish
    /// in bursts (redirects, frames), and each save serializes every tab's
    /// back/forward history, so one save covers the burst.
    func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            saveTabs()
        }
    }

    /// Writes only what changed. It used to delete and insert every tab, which
    /// on a phone with two hundred of them wrote four hundred rows (and as many
    /// change-history rows) a page, and left the store ten times its data.
    func saveTabs() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let context = tabContext else { return }
        let records = (try? context.fetch(FetchDescriptor<SavedTab>())) ?? []
        var byID: [UUID: SavedTab] = [:]
        for record in records {
            if byID[record.tabID] == nil { byID[record.tabID] = record } else { context.delete(record) }
        }
        var open = Set<UUID>()
        for (index, tab) in tabs.enumerated() where !tab.isPrivate {
            guard let url = tab.url else { continue }
            open.insert(tab.id)
            let address = url.absoluteString
            // A live page's state is encoded by WebKit: once per save.
            let state = tab.interactionState
            guard let record = byID[tab.id] else {
                context.insert(SavedTab(tabID: tab.id, url: address, title: tab.title, order: index,
                                        lastActive: tab.lastActive, interactionState: state))
                continue
            }
            // Assigned only when different: an assignment counts as a change.
            if record.url != address { record.url = address }
            if record.title != tab.title { record.title = tab.title }
            if record.order != index { record.order = index }
            if record.lastActive != tab.lastActive { record.lastActive = tab.lastActive }
            if record.interactionState != state { record.interactionState = state }
        }
        for (id, record) in byID where !open.contains(id) { context.delete(record) }
        if context.hasChanges { try? context.save() }
    }

    // MARK: Tabs

    func select(_ tab: BrowserTab) {
        HitchWatch.start("select tab")
        finishHidingItems()
        // Split View asked for: whatever the bar opens (an address, a search, a
        // pin, a tab already open) is the half below.
        if split == nil, let first = pendingSplitWith, first != tab.id,
           tabs.contains(where: { $0.id == first }), tabs.contains(where: { $0.id == tab.id }) {
            pendingSplitWith = nil
            splitFraction = 0.5
            split = Split(top: first, bottom: tab.id)
        }
        // In Split View, a tab from elsewhere takes the place of the half in use.
        if var current = split, !current.contains(tab.id), let selectedID {
            if current.top == selectedID { current.top = tab.id } else { current.bottom = tab.id }
            split = current
        }
        let previous = selectedTab
        selectedID = tab.id
        tab.lastActive = .now
        tab.wake()
        isBarCollapsed = false
        Task {
            await previous?.captureSnapshot()
            await enforceLiveLimit()
        }
    }

    func open(_ url: URL, inNewTab: Bool = false, isPrivate: Bool = false) {
        if !inNewTab, let tab = selectedTab, tab.isPrivate == isPrivate {
            tab.load(url)
        } else if !isPrivate, let tab = takePreloaded(url) {
            tab.delegate = self
            tabs.append(tab)
            select(tab)
            // Finished before it was taken: its visit wasn't recorded yet.
            if !tab.isLoading, let shown = tab.url { self.tab(tab, didFinishLoading: shown, title: tab.title) }
            // Moved from behind everything into its place: until it scrolls,
            // WebKit keeps a fixed header where the old layout had it.
            Task {
                await Task.yield()
                guard let scrollView = tab.webView?.scrollView else { return }
                let top = CGPoint(x: 0, y: -scrollView.adjustedContentInset.top)
                scrollView.setContentOffset(CGPoint(x: 0, y: top.y + 1), animated: false)
                scrollView.setContentOffset(top, animated: false)
            }
        } else {
            let tab = BrowserTab(url: url, isPrivate: isPrivate)
            if isPrivate { PrivacyLock.shared.opened(tab.id) }
            tab.delegate = self
            tabs.append(tab)
            select(tab)
        }
        panel = .none
    }

    // MARK: Preloading

    /// The page Go would open in a new tab, already loading out of sight while
    /// you finish typing, as Safari's Preload Top Hit does. Most of a page's
    /// wait (the connection, the HTML, its scripts) is over before Go.
    @ObservationIgnored private var preloaded: (url: URL, tab: BrowserTab)?
    @ObservationIgnored private var preloadWait: Task<Void, Never>?

    /// The command bar's top row, each time it changes: a site to open, or nil.
    /// Waits for typing to pause, so every letter doesn't start a page.
    func preloadTopHit(_ url: URL?) {
        preloadWait?.cancel()
        let opensNewTab = commandMode == .newTab || (commandMode == .currentTab && selectedTab == nil)
        guard let url, opensNewTab, launcherContext == .web, !isCurrentPage(url) else {
            dropPreload()
            return
        }
        if preloaded?.url == url { return }
        preloadWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.panel == .command else { return }
            self.dropPreload()
            let tab = BrowserTab(url: url)
            tab.wake()
            // In the window, behind everything: WebKit only lays out and paints
            // a page that's on screen, and one at the screen's size doesn't
            // reflow when it's shown. The page is drawn before Go, not after.
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first, let webView = tab.webView {
                webView.frame = window.bounds
                window.insertSubview(webView, at: 0)
            }
            self.preloaded = (url, tab)
        }
    }

    func dropPreload() {
        preloadWait?.cancel()
        preloaded?.tab.close()
        preloaded = nil
    }

    private func takePreloaded(_ url: URL) -> BrowserTab? {
        preloadWait?.cancel()
        guard let preloaded, preloaded.url == url else {
            dropPreload()
            return nil
        }
        self.preloaded = nil
        return preloaded.tab
    }

    // MARK: Welcome

    /// The first time roko opens (or when asked for again in Settings).
    var showsOnboarding = !UserDefaults.standard.bool(forKey: Onboarding.doneKey)
        || ProcessInfo.processInfo.arguments.contains("-onboarding")

    /// Done or skipped: straight into the bar, ready to type.
    func finishOnboarding() {
        showsOnboarding = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            showCommandBar()
        }
    }

    // MARK: Peek

    /// A link touched and held: its page, loading live in the menu's preview
    /// until it's opened or the menu goes.
    @ObservationIgnored private var peek: BrowserTab?

    private func closePeek() {
        peek?.close()
        peek = nil
    }

    /// The peeked page becomes a tab of its own, scrolled where you left it:
    /// on screen, or next to this one for later.
    private func openPeek(showing: Bool) {
        guard let tab = peek else { return }
        peek = nil
        tab.delegate = self
        let after = tabs.firstIndex { $0.id == selectedID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: min(after, tabs.count))
        if showing {
            select(tab)
        } else {
            tab.lastActive = .now.addingTimeInterval(-1)
            Task {
                await tab.captureSnapshot()
                await enforceLiveLimit()
            }
            showToast("Opened in the background")
        }
        if !tab.isLoading, let shown = tab.url { self.tab(tab, didFinishLoading: shown, title: tab.title) }
        scheduleSave()
    }

    /// Read Later, once the page has loaded enough to have its text.
    private func savePeekForLater() {
        guard let tab = peek else { return }
        peek = nil
        Task {
            for _ in 0..<40 where tab.isLoading { try? await Task.sleep(for: .milliseconds(200)) }
            showToast(await ReadLater.shared.save(tab))
            tab.close()
        }
    }

    // MARK: Mini player

    /// A tab out of sight with sound or video playing (or paused there): the
    /// small player above the bar works it.
    var playerTab: BrowserTab? {
        // Not while it's in Picture in Picture: it has its own window then.
        let candidates = tabs.filter { $0.id != selectedID && split?.contains($0.id) != true
            && $0.media != nil && $0.media?.isFloating != true && !$0.playerDismissed && $0.isLive }
        return candidates.first { $0.media?.playing == true } ?? candidates.first
    }

    func togglePlayback(_ tab: BrowserTab) {
        Task { _ = await PageWatch.call(tab.webView, "toggle") }
    }

    func skip(_ tab: BrowserTab, by seconds: Double) {
        Task { _ = await PageWatch.call(tab.webView, "skip", ["seconds": seconds]) }
    }

    /// Picture in Picture. iOS only starts it for a video on screen, so the
    /// video's tab comes up for a moment, the video goes into its own window,
    /// and you're back on the page you were reading.
    func pictureInPicture(_ tab: BrowserTab) {
        let reading = selectedTab
        if reading?.id != tab.id { select(tab) }
        Task {
            // On screen and laid out before asking.
            for _ in 0..<20 where tab.webView?.window == nil { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(250))
            guard let webView = tab.webView else { return }
            // evaluateJavaScript counts as a tap on the page, which iOS wants for this.
            let asked = (try? await webView.evaluateJavaScript("window.__rokoPage ? window.__rokoPage.pictureInPicture() : false",
                                                              in: nil, contentWorld: PageWatch.world)) as? Bool ?? false
            var floating = false
            for _ in 0..<15 where asked && !floating {
                try? await Task.sleep(for: .milliseconds(100))
                floating = (try? await webView.evaluateJavaScript("window.__rokoPage ? window.__rokoPage.inPictureInPicture() : false",
                                                                  in: nil, contentWorld: PageWatch.world)) as? Bool ?? false
            }
            if floating {
                if let reading, reading.id != tab.id, tabs.contains(where: { $0.id == reading.id }) { select(reading) }
            } else {
                showProblem("This video can't play in a window")
            }
        }
    }

    func fullScreen(_ tab: BrowserTab) {
        select(tab)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            _ = await PageWatch.call(tab.webView, "fullscreen")
        }
    }

    /// Closed: paused, and gone until it plays again.
    func closePlayer(_ tab: BrowserTab) {
        tab.playerDismissed = true
        Task { _ = await PageWatch.call(tab.webView, "pause") }
    }

    // MARK: Live band

    /// What's going on right now, in the band under the page: sound playing in
    /// another tab, parking counting down, a to-do due within the hour.
    enum LiveItem: Identifiable {
        case media(BrowserTab)
        case parking(Parking.Session)
        case todo(Todo)
        /// Today's (or overdue), not due yet: quiet, in the thin strip until asked for.
        case today(Todo)

        var id: String {
            switch self {
            case .media(let tab): "media-\(tab.id)"
            case .parking(let session): "parking-\(session.startedAt.timeIntervalSince1970)"
            case .todo(let todo): "todo-\(todo.persistentModelID.hashValue)"
            case .today(let todo): "today-\(todo.persistentModelID.hashValue)"
            }
        }

        /// Asks for the full band by itself: everything but today's quiet to-dos.
        var isLoud: Bool {
            if case .today = self { return false }
            return true
        }
    }

    var liveItems: [LiveItem] {
        _ = liveClock
        var items: [LiveItem] = []
        if Preferences.bandMedia, let tab = playerTab { items.append(.media(tab)) }
        if Preferences.bandParking, let session = Parking.shared.active, hiddenParking != session.startedAt {
            items.append(.parking(session))
        }
        // Each to-do due is a page of its own, soonest first.
        if Preferences.bandDue { items += dueTodos.filter { !$0.done }.map { .todo($0) } }
        // Then the rest of today, quietly.
        if Preferences.bandToday, !todayHidden { items += todayTodos.filter { !$0.done }.map { .today($0) } }
        return items
    }

    /// Only today's quiet to-dos and not opened: the band stays a thin strip.
    var bandShowsStrip: Bool {
        bandMinimized || (!liveItems.contains(where: \.isLoud) && !todayExpanded)
            // One full-height thing at a time. The row waits as a
            // strip while the bar is up and takes its place once it folds away.
            || (barInBand && !isBarCollapsed && !bandOpenedOverBar)
    }

    /// The thin strip opened into the band.
    func expandBand() {
        if barInBand && !isBarCollapsed { bandOpenedOverBar = true }
        if liveItems.contains(where: \.isLoud) { bandMinimized = false } else { todayExpanded = true }
    }

    /// The band pulled down into the strip.
    func collapseBand() {
        if bandOpenedOverBar {
            bandOpenedOverBar = false
            return
        }
        if liveItems.contains(where: \.isLoud) { bandMinimized = true } else { todayExpanded = false }
    }

    /// The bar lies in the band under the page.
    var barInBand = false
    /// The strip opened by hand with the bar up; the next scroll puts it back.
    var bandOpenedOverBar = false
    /// Which of them the band shows, swiped sideways.
    var livePage = 0
    /// Pulled down: a thin strip, still live; a tap brings the band back.
    var bandMinimized = false
    /// Moves on twice a minute, so what's due comes and goes by itself.
    private(set) var liveClock = Date.now
    private(set) var dueTodos: [Todo] = []
    /// The rest of today's to-dos (and overdue ones), timed ones first.
    private(set) var todayTodos: [Todo] = []
    /// Today's strip opened by a tap.
    private var todayExpanded = false
    /// Today's strip pulled away; back the next time roko opens.
    private var todayHidden = false
    /// Parking put away from the band (by when it started); a new session shows again.
    private var hiddenParking: Date?
    @ObservationIgnored private var dismissedTodos = Set<PersistentIdentifier>()
    @ObservationIgnored private var liveTicker: Task<Void, Never>?

    /// The to-dos whose time is within the next hour, soonest first.
    func refreshLive() {
        // Not while roko is away (sound playing on): nothing is looking.
        guard let context, UIApplication.shared.applicationState != .background else { return }
        let now = Date.now
        let todos = (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { !$0.done && $0.time != nil }))) ?? []
        let due = todos
            .filter { todo in
                guard let time = todo.time, !dismissedTodos.contains(todo.persistentModelID) else { return false }
                // From an hour before its time until its time; after that it's overdue, in the strip.
                return time > now && time < now.addingTimeInterval(60 * 60)
            }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        let dueIDs = Set(due.map(\.persistentModelID))
        let open = (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { !$0.done }))) ?? []
        let today = open
            .filter { todo in
                guard !dueIDs.contains(todo.persistentModelID), !dismissedTodos.contains(todo.persistentModelID) else { return false }
                let section = TodoSection.of(todo, now: now)
                return section == .today || section == .overdue
            }
            .sorted { a, b in
                switch (a.time, b.time) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.createdAt < b.createdAt
                }
            }
        // Assigned only when different: each assignment has the whole screen
        // look again, and the ticker runs twice a minute for the life of the app.
        if due.map(\.persistentModelID) != dueTodos.map(\.persistentModelID) { dueTodos = due }
        if today.map(\.persistentModelID) != todayTodos.map(\.persistentModelID) { todayTodos = today }
        if Parking.shared.active?.startedAt != lastParking {
            lastParking = Parking.shared.active?.startedAt
            liveClock = now
        }
    }
    @ObservationIgnored private var lastParking: Date?

    func startLiveTicker() {
        liveTicker?.cancel()
        refreshLive()
        liveTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refreshLive()
            }
        }
    }

    /// Off the band: sound pauses; parking and a to-do just leave it.
    func dismissLive(_ item: LiveItem) {
        bandMinimized = false
        switch item {
        case .media(let tab): closePlayer(tab)
        case .parking(let session): hiddenParking = session.startedAt
        case .todo(let todo):
            dismissedTodos.insert(todo.persistentModelID)
            refreshLive()
        case .today:
            todayHidden = true
            todayExpanded = false
        }
    }

    /// Ticked off from the band.
    func complete(_ todo: Todo) {
        todo.done = true
        todo.doneAt = .now
        try? context?.save()
        showToast("Done: \(todo.title)")
        refreshLive()
    }

    // MARK: Hide Distracting Items

    func startHidingItems() {
        guard let webView = selectedTab?.webView, webView.url?.host() != nil else { return }
        panel = .none
        picker.changed = { [weak self] count in self?.hidingItems = count }
        picker.start(in: webView)
        hidingItems = 0
    }

    func undoHiddenItem() {
        picker.undo()
    }

    func finishHidingItems() {
        guard hidingItems != nil else { return }
        let count = picker.finish()
        hidingItems = nil
        if count > 0, let host = selectedTab?.url?.displayHost {
            showToast(count == 1 ? "Hidden on \(host) from now on" : "\(count) things hidden on \(host) from now on")
        }
    }

    /// Everything you hid on this site shows again.
    func showHiddenItems() {
        guard let tab = selectedTab, let host = tab.url?.host() else { return }
        HiddenItems.shared.forget(host)
        panel = .none
        tab.webView?.reload()
    }

    /// A tab you closed, kept with its back/forward history so it can come
    /// back as it was. Only while roko is open, and never a private tab.
    struct ClosedTab {
        let id: UUID
        let url: URL
        let title: String
        let state: Data?
        let index: Int
    }

    /// Most recent last; the oldest drop off past ten.
    private(set) var recentlyClosed: [ClosedTab] = []

    /// The last tab you closed, back where it was and on screen.
    func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast() else { return }
        let tab = BrowserTab(url: closed.url, title: closed.title, restoreState: closed.state)
        tab.delegate = self
        tabs.insert(tab, at: min(closed.index, tabs.count))
        select(tab)
        panel = .none
        scheduleSave()
    }

    /// Everything one Close All took, ready to come back together.
    struct ClosedGroup {
        let tabs: [ClosedTab]
        let selectedIndex: Int?
    }

    /// The last Close All, while the switcher still offers it back.
    var closedGroup: ClosedGroup?

    /// Tabs that Close All would close now: private ones stay, being the ones
    /// that couldn't come back, and go only when they're all that's left.
    var tabsToCloseAll: [BrowserTab] {
        let ordinary = tabs.filter { !$0.isPrivate }
        return ordinary.isEmpty ? tabs : ordinary
    }

    /// Closes them at once and shows the switcher, with Undo.
    func closeAllTabs() {
        let closing = tabsToCloseAll
        // Taken before anything closes, so Undo finds every tab's place. The
        // selected one goes last, so no other tab wakes up on the way out.
        let group = ClosedGroup(
            tabs: tabs.enumerated().compactMap { index, tab in
                guard !tab.isPrivate, let url = tab.url else { return nil }
                return ClosedTab(id: tab.id, url: url, title: tab.title, state: tab.interactionState, index: index)
            },
            selectedIndex: tabs.firstIndex { $0.id == selectedID && !$0.isPrivate })
        // Their pictures stay on disk for Undo; the next launch sweeps up the rest.
        for tab in closing where tab.id != selectedID { close(tab, keepingPicture: true) }
        if let selectedTab, closing.contains(where: { $0.id == selectedTab.id }) { close(selectedTab, keepingPicture: true) }
        closedGroup = group.tabs.isEmpty ? nil : group
        panel = .tabs
    }

    /// A Close All taken back: every tab where it was, with its history and picture.
    func reopenClosedGroup() {
        guard let group = closedGroup else { return }
        closedGroup = nil
        recentlyClosed.removeLast(min(group.tabs.count, recentlyClosed.count))
        for closed in group.tabs {
            // The same id as before: its picture is still on disk under it.
            let tab = BrowserTab(id: closed.id, url: closed.url, title: closed.title, restoreState: closed.state)
            tab.delegate = self
            tabs.insert(tab, at: min(closed.index, tabs.count))
            if closed.index == group.selectedIndex { select(tab) }
        }
        scheduleSave()
    }

    func close(_ tab: BrowserTab, keepingPicture: Bool = false) {
        HitchWatch.start("close tab")
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if !tab.isPrivate, let url = tab.url {
            recentlyClosed.append(ClosedTab(id: tab.id, url: url, title: tab.title, state: tab.interactionState, index: index))
            if recentlyClosed.count > 10 { recentlyClosed.removeFirst() }
        }
        tab.close(keepingPicture: keepingPicture)
        tabs.remove(at: index)
        // Half of a split closed: the other half has the screen.
        if let current = split, current.contains(tab.id) {
            split = nil
            if let other = self.tab(current.top == tab.id ? current.bottom : current.top) {
                if selectedID == tab.id { select(other) }
            }
        }
        if tab.isPrivate, !tabs.contains(where: \.isPrivate) { WebViewFactory.endPrivateSession() }
        defer { scheduleSave() }
        if selectedID == tab.id {
            if let next = tabs.max(by: { $0.lastActive < $1.lastActive }) {
                select(next)
            } else {
                selectedID = nil
            }
        }
    }

    func selectNeighbor(offset: Int) {
        guard let tab = selectedTab, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = index + offset
        guard tabs.indices.contains(target) else { return }
        select(tabs[target])
    }

    private func enforceLiveLimit() async {
        // Never one with a form half filled in, or playing, or the other half of
        // a split: hibernating would lose it, or blank it on screen.
        let live = tabs.filter { $0.isLive && $0.id != selectedID && !$0.isBusy && split?.contains($0.id) != true }
            .sorted { $0.lastActive > $1.lastActive }
        for tab in live.dropFirst(Self.liveTabLimit - 1) {
            await tab.hibernate()
        }
    }

    // MARK: Commands

    /// A brief confirmation above the bar, such as "Copied 3.11 mi".
    /// roko's own links (from its reminders, the parking Live Activity) and
    /// pages handed over by notifications or other apps.
    func handleLink(_ url: URL) {
        LaunchClock.mark("link")
        switch url.absoluteString {
        case "roko://today": panel = .today
        case "roko://todo": panel = .todos
        case "roko://shopping": panel = .shopping
        case "roko://read-later": panel = .readLater
        case "roko://feed": panel = .feed
        // The parking timer: the bar, with the time left on top.
        case "roko://parking", "roko://bar": showCommandBar()
        case "roko://parking/extend": Parking.shared.extend()
        // Control Center, the Lock Screen, Siri and Shortcuts (RokoIntents).
        case "roko://new-tab": panel = .none; showCommandBar()
        case "roko://private-tab": panel = .none; showCommandBar(mode: .privateTab)
        case "roko://ask": panel = .none; showCommandBar()
        case "roko://downloads": panel = .downloads
        // From another app's share sheet (ShareExtension): a link, or words to ask about.
        case _ where url.scheme == "roko" && (url.host() == "open" || url.host() == "ask"):
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            if url.host() == "open", let page = value.flatMap(URL.init(string:)), page.scheme?.hasPrefix("http") == true {
                openFromOutside(page)
            } else if url.host() == "ask", let question = value, !question.isEmpty {
                browse(for: question)
            }
        default:
            guard url.scheme?.hasPrefix("http") == true else { return }
            openFromOutside(url)
        }
    }

    /// A link from another app is what you came for, so it goes over whatever is up, sheets too.
    /// That includes the day's first Today, which then waits for your next return.
    private func openFromOutside(_ page: URL) {
        lastOutsideLink = .now
        if panel == .today { TodayModel.forgetIfJustShown() }
        panel = .none
        reader = nil
        summary = nil
        browseForMe = nil
        open(page, inNewTab: true)
    }

    private var lastOutsideLink: Date?
    var linkJustArrived: Bool { lastOutsideLink.map { Date.now.timeIntervalSince($0) < 2 } ?? false }

    /// Something just removed, a tap from coming back: the switcher's Reopen, for the rest of the app.
    /// Or something that went wrong, with the one thing that helps if there is one.
    struct UndoOffer: Identifiable {
        let id = UUID()
        let text: String
        var action: String? = "Undo"
        var isProblem = false
        let undo: () -> Void
    }
    private(set) var undoOffer: UndoOffer?
    private var undoTask: Task<Void, Never>?

    func offerUndo(_ text: String, undo: @escaping () -> Void) {
        undoOffer = UndoOffer(text: text, undo: undo)
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { undoOffer = nil }
        }
    }

    /// Not a confirmation: it stays long enough to read, feels different, and can carry a way out.
    func showProblem(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) {
        toast = nil
        toastTask?.cancel()
        undoOffer = UndoOffer(text: text, action: action, isProblem: true, undo: perform)
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { undoOffer = nil }
        }
    }

    /// iOS's page for roko, for what only the iPhone's Settings can allow.
    static func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    func takeUndo() {
        undoOffer?.undo()
        undoOffer = nil
        undoTask?.cancel()
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { toast = nil }
        }
    }

    /// `fresh`: a new picture of the page for its card. Not from a pinch,
    /// which would catch the page shrunk under the fingers.
    func showTabs(fresh: Bool = true) {
        HitchWatch.start("tabs")
        // Refresh the current tab's card while its page is still on screen.
        if fresh { Task { await selectedTab?.captureSnapshot() } }
        panel = .tabs
    }

    func showCommandBar(prefill: String = "", mode: CommandMode = .newTab,
                        context: LauncherContext = .web, over screen: Panel = .none) {
        HitchWatch.start("launcher")
        dismissOffers()
        commandPrefill = prefill
        commandMode = mode
        launcherContext = context
        launcherReturn = screen
        // The launcher grows its field out of the bar's capsule itself (LauncherMorph).
        panel = .command
        // The address bar offers the copied link itself.
        copiedLinkOffer = false
    }

    /// Opens a URL from the command bar, honouring the mode it was opened in.
    func openFromCommandBar(_ url: URL) {
        switch commandMode {
        case .currentTab: open(url, inNewTab: selectedTab == nil)
        case .newTab: open(url, inNewTab: true)
        case .privateTab: open(url, inNewTab: true, isPrivate: true)
        }
    }

    /// + held: the launcher opens out of it, listening. Asked for the
    /// microphone the first time (then hold again).
    func startVoice() {
        guard !voiceListening else { return }
        guard VoiceInput.isAuthorized else {
            Task {
                if !(await VoiceInput.authorize()) {
                    showProblem("Allow the microphone and speech", action: "Settings", perform: Self.openAppSettings)
                }
            }
            return
        }
        do {
            // Your own sites, for the recognizers to expect by name.
            VoiceInput.expectedSites = Array(pins().compactMap { URL(string: $0.url)?.displayHost }
                + history(matching: "", limit: 60).compactMap { URL(string: $0.url)?.displayHost })
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .prefix(20)
                .flatMap { host -> [String] in
                    let parts = host.split(separator: ".")
                    guard parts.count >= 2 else { return [host] }
                    return ["\(parts[parts.count - 2]) točka \(parts.last!)", String(parts[parts.count - 2])]
                }
            let tick = UIImpactFeedbackGenerator(style: .heavy)
            tick.prepare()
            try VoiceInput.shared.start()
            tick.impactOccurred()
            voiceListening = true
            voiceResult = nil
            // Asked from the launcher's own mic: it's already open, set up as it should be.
            if panel != .command { showCommandBar() }
        } catch is VoiceBusy {
            // Let go a moment ago and still hearing the end of it: this hold waits.
        } catch {
            showProblem("Couldn't start listening")
        }
    }

    /// + let go. Let go before saying anything (a quick hold), it keeps
    /// listening and stops by itself after a pause in the speech, or eight
    /// seconds of nothing; tapping the field's mark stops it too.
    func endVoice() {
        guard voiceListening else { return }
        let voice = VoiceInput.shared
        guard voice.lastVoiceAt == nil, voice.partial.isEmpty else { return finishVoice() }
        voiceHandsFree?.cancel()
        voiceHandsFree = Task {
            while !Task.isCancelled, voiceListening {
                try? await Task.sleep(for: .milliseconds(200))
                let now = Date.now
                if let last = voice.lastVoiceAt, !voice.partial.isEmpty, now.timeIntervalSince(last) > 1.4 { break }
                if voice.lastVoiceAt == nil, now.timeIntervalSince(voice.startedAt) > 8 { break }
            }
            if !Task.isCancelled { finishVoice() }
        }
    }
    private var voiceHandsFree: Task<Void, Never>?
    /// Bumped when listening is called off: words that arrive after that are dropped.
    @ObservationIgnored private var voiceSession = 0

    /// The launcher closed while listening: stop, and forget what was heard.
    func cancelVoice() {
        voiceSession += 1
        voiceHandsFree?.cancel()
        voiceHandsFree = nil
        guard voiceListening else { return }
        voiceListening = false
        voiceResult = nil
        VoiceInput.shared.cancel()
    }

    /// Stop now: what was said is opened when it's a site roko knows, and
    /// otherwise goes into the launcher as if typed, its best row ready.
    /// Nothing heard, the launcher stays, with the keyboard.
    func finishVoice() {
        guard voiceListening else { return }
        voiceHandsFree?.cancel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let session = voiceSession
        Task {
            let heard = await VoiceInput.shared.stop()
            // The bar was closed while the last words came in: they don't act.
            guard session == voiceSession else { return }
            voiceListening = false
            guard let heard, !heard.isEmpty else {
                if panel == .command { showProblem("Didn't catch that") }
                return
            }
            let meaning = VoiceCommand.interpret(heard) { stem in
                self.history(matching: stem, limit: 12).compactMap { URL(string: $0.url)?.displayHost }
            }
            switch meaning {
            case .open(let url):
                panel = .none
                openFromCommandBar(url)
            case .words(let text) where ResearchDepth.prefersAnswer(text) && !TodoIntent.isLikely(text):
                // A question said ("koji su rezultati izbora u srbiji"): answered at once.
                panel = .none
                browse(for: text)
            case .words(let text):
                // A site's name said ("Sportske novosti"): the site, opened.
                let rows = CommandRanker.rank(query: text, browser: self, suggestions: [])
                if !ResearchDepth.prefersAnswer(text), !TodoIntent.isLikely(text),
                   let site = CommandRanker.siteNamed(text.lowercased(), in: rows) {
                    panel = .none
                    switch site.action {
                    case .open(let url): openFromCommandBar(url)
                    case .openPin(let pin): open(pin)
                    case .switchTab(let tab): select(tab)
                    default: voiceResult = text
                    }
                } else {
                    voiceResult = text
                }
            }
        }
    }

    /// A question about a summarized page: Browse for Me, with the summary as
    /// what's already been said, so the answer builds on it.
    func ask(_ question: String, about summary: SummaryModel) {
        let session = BrowseSession(question: question,
                                    context: [(question: "Summarize \(summary.title) (\(summary.host))", answer: summary.text)])
        summaryCoversPage = false
        self.summary = nil
        browseForMe = session
    }

    /// Opens the full-screen summary: the page on screen shrinks into its card.
    func summarize(from handoff: PullHandoff? = nil) {
        guard let tab = selectedTab, let webView = tab.webView, tab.url != nil else { return }
        let model = SummaryModel(title: tab.displayTitle, host: tab.url?.displayHost ?? "", snapshot: nil)
        if let handoff {
            HitchWatch.start("summarize")
            // From a pull: no waiting, the card is already on its way.
            model.snapshot = handoff.snapshot
            model.handoff = handoff
            summary = model
            // A private page's summary isn't kept: the cache is on disk.
            model.start(webView: webView, url: tab.isPrivate ? nil : tab.url)
            return
        }
        Task {
            // The page as it is on screen, so it can shrink into the card.
            model.snapshot = await tab.viewportSnapshot() ?? tab.snapshot
            presentAfterPanelCloses { self.summary = model }
            model.start(webView: webView, url: tab.isPrivate ? nil : tab.url)
        }
    }

    // MARK: Read Later

    /// Puts the page aside, with its text as it is now.
    func saveForLater() {
        guard let tab = selectedTab, tab.url != nil else { return }
        panel = .none
        Task { showToast(await ReadLater.shared.save(tab)) }
    }

    /// One summary across every unread saved page, or across one group of them.
    func summarizeSaved(_ group: ReadLaterGroup? = nil) {
        let pages = group.map(ReadLater.shared.pages(in:)) ?? ReadLater.shared.unread
        guard !pages.isEmpty else { return }
        let model = DigestModel(pages: pages, subject: group?.name)
        digest = model
        model.start()
    }

    /// A saved page, in a new tab: it counts as read.
    func openSaved(_ page: ReadLaterPage, searching: String = "") {
        if readLaterBeside, uprightFoldOpen {
            finishSavedBeside()
            savedBeside = page.id
            openBeside(page.url)
            return
        }
        readLaterBeside = false
        ReadLater.shared.markRead(page.id)
        digest = nil
        panel = .none
        open(page.url, inNewTab: true)
        selectedTab?.savedPlace = SavedPlace(page: page.id, query: searching)
    }

    /// Back to the list, where it was left. The tab has done its job, and stays among
    /// the closed tabs; it goes once the list covers it, so no other page shows meanwhile.
    func returnToSaved(from tab: BrowserTab) {
        savedPlaceToRestore = tab.savedPlace
        withAnimation(.snappy(duration: 0.32)) { panel = .readLater }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            close(tab)
        }
    }

    // MARK: Feed

    /// A story from the feed, in Reader: it counts as read.
    func read(_ story: NewsStory) {
        FeedStore.shared.markRead([story.link])
        let model = ReaderModel(host: story.host, story: story)
        reader = model
        Task { await model.load() }
    }

    /// Several sites' stories about one event, compared: they count as read.
    func compare(_ stories: [NewsStory]) {
        FeedStore.shared.markRead(stories.map(\.link))
        let model = DigestModel(comparing: stories)
        digest = model
        model.start()
    }

    /// A story as the page it came from, in a new tab.
    func openOriginal(of story: NewsStory) {
        openPage(story.link)
    }

    /// Out of the feed to a page of its own, in a new tab.
    func openPage(_ url: URL) {
        reader = nil
        digest = nil
        panel = .none
        open(url, inNewTab: true)
    }

    /// This page's site, or this section of it, is among the sources.
    var followsThisPage: Bool {
        guard let url = selectedTab?.url, let host = url.host()?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return NewsSite.chosen.contains { $0.host == bare && ($0.path == nil || path.hasPrefix(($0.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))) }
    }

    /// Follows what this page is. An article: its site. A site's section, "bbc.com/sport":
    /// that section, if it can be followed, or failing that its site.
    func followPage() {
        guard let tab = selectedTab, let url = tab.url, let host = url.host() else { return }
        panel = .none
        Task {
            let isArticle = (try? await tab.webView?.evaluateJavaScript("""
                ((document.querySelector('meta[property="og:type"]') || {}).content || "") === "article"
                """) as? Bool) ?? false
            let hasPath = !url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            var site: NewsSite?
            if hasPath, !isArticle { site = await TodayNews.find(url.absoluteString) }
            if site == nil { site = await TodayNews.find(host) }
            guard let site else { return showProblem("Found no stories to follow here") }
            if !NewsSite.chosen.contains(where: { $0.id == site.id }) { NewsSite.chosen.append(site) }
            showToast("Following \(site.name ?? site.host) in News")
            await FeedStore.shared.refresh(immediately: true)
        }
    }

    /// A question about the saved pages: Browse for Me, with the digest as what's been said.
    func ask(_ question: String, about digest: DigestModel) {
        let titles = digest.pages.map(\.title).joined(separator: "; ")
        let asked = digest.isComparison ? "Compare how these sources report it: \(titles)" : "Summarize my saved pages: \(titles)"
        let session = BrowseSession(question: question, context: [(question: asked, answer: digest.text)])
        self.digest = nil
        panel = .none
        browseForMe = session
    }

    /// The article as Markdown on the clipboard.
    func copyAsMarkdown() {
        guard let webView = selectedTab?.webView else { return }
        panel = .none
        Task {
            guard let markdown = await PageReader.markdown(webView) else { return showProblem("Nothing to copy on this page") }
            UIPasteboard.general.string = markdown
            showToast("Copied as Markdown")
        }
    }

    private func finishSavedBeside() {
        if let savedBeside { ReadLater.shared.markRead(savedBeside) }
        savedBeside = nil
    }

    /// The recipe on this page, for the kitchen.
    func cookThisPage() {
        guard let webView = selectedTab?.webView else { return }
        Task {
            guard let recipe = await RecipeReader.read(webView) else {
                panel = .none
                return showProblem("No recipe found on this page")
            }
            presentAfterPanelCloses { self.cook = CookModel(recipe: recipe) }
        }
    }

    func openReader() {
        guard let tab = selectedTab, let webView = tab.webView else { return }
        let model = ReaderModel(host: tab.url?.displayHost ?? "")
        presentAfterPanelCloses { self.reader = model }
        Task { await model.load(from: webView) }
    }

    /// A source from Browse for Me, beside the answer on an open Duo. Another
    /// source takes its place, rather than a tab for each.
    func openBeside(_ url: URL) {
        if pageBeside, let tab = selectedTab {
            tab.load(url)
        } else {
            open(url, inNewTab: true)
            pageBeside = true
        }
    }

    func closeBeside() {
        pageBeside = false
        finishSavedBeside()
        if let tab = selectedTab { close(tab) }
    }

    func browse(for query: String) {
        let session = BrowseSession(question: query)
        presentAfterPanelCloses { self.browseForMe = session }
    }

    /// SwiftUI drops a sheet presented while another is still sliding away, so
    /// when a sheet panel is open, wait for it to finish closing first.
    private func presentAfterPanelCloses(_ present: @escaping () -> Void) {
        let wasSheet = panel == .settings || reader != nil
        panel = .none
        reader = nil
        guard wasSheet else { return present() }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            present()
        }
    }

    // MARK: Pins

    func pins() -> [Pin] {
        (try? context?.fetch(FetchDescriptor<Pin>(sortBy: [SortDescriptor(\.order)]))) ?? []
    }

    /// Pins are pages, not sites: two pages of one site can both be pinned.
    func isPinned(_ url: URL?) -> Bool {
        guard let url else { return false }
        return pins().contains { pin in URL(string: pin.url).map(Self.samePage) == Self.samePage(url) }
    }

    func togglePin(for tab: BrowserTab) {
        guard let context, let url = tab.url else { return }
        if let existing = pins().first(where: { pin in URL(string: pin.url).map(Self.samePage) == Self.samePage(url) }) {
            context.delete(existing)
        } else {
            context.insert(Pin(url: url, title: tab.displayTitle, order: pins().count))
        }
        try? context.save()
    }

    func unpin(_ pin: Pin) {
        context?.delete(pin)
        try? context?.save()
    }

    /// A pin always goes to the page that was pinned. A tab already showing
    /// exactly that page is reused; one elsewhere on the same site is left as
    /// it is, and the pinned page opens in a new tab.
    func open(_ pin: Pin) {
        guard let url = URL(string: pin.url) else { return }
        let pinned = Self.samePage(url)
        if let tab = tabs.first(where: { !$0.isPrivate && $0.url.map(Self.samePage) == pinned }) {
            select(tab)
            panel = .none
        } else {
            open(url, inNewTab: true)
        }
    }

    /// The page an address points at, ignoring "www.", http vs https, a
    /// trailing slash and the #section within it.
    /// The page on screen: a copied link to it isn't worth offering.
    func isCurrentPage(_ url: URL) -> Bool {
        selectedTab?.url.map(Self.samePage) == Self.samePage(url)
    }

    private static func samePage(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.scheme = "https"
        if let host = components?.host, host.hasPrefix("www.") { components?.host = String(host.dropFirst(4)) }
        var page = components?.string ?? url.absoluteString
        if page.hasSuffix("/") { page.removeLast() }
        return page.lowercased()
    }

    // MARK: History

    /// Forgets a page: every visit to that address, or to any address on that
    /// site when `wholeSite` (as the launcher's site row stands for all of them).
    /// What was forgotten, to put back: address, title, last visit, visits.
    typealias ForgottenPage = (url: String, title: String, visitedAt: Date, visitCount: Int)

    @discardableResult
    func forget(_ url: URL, wholeSite: Bool = false) -> [ForgottenPage] {
        guard let context else { return [] }
        var forgotten: [ForgottenPage] = []
        let host = url.displayHost
        let all = (try? context.fetch(FetchDescriptor<HistoryEntry>())) ?? []
        // The launcher shows the same page under two addresses as one row
        // (same site, same title): forgetting the row forgets both.
        let titles = Set(all.filter { $0.url == url.absoluteString && !$0.title.isEmpty }.map(\.title))
        for entry in all {
            let onSite = URL(string: entry.url)?.displayHost == host
            if wholeSite ? onSite : entry.url == url.absoluteString || (onSite && titles.contains(entry.title)) {
                forgotten.append((entry.url, entry.title, entry.visitedAt, entry.visitCount))
                context.delete(entry)
            }
        }
        try? context.save()
        historyIndex.rebuild(from: context.container)
        return forgotten
    }

    func remember(_ pages: [ForgottenPage]) {
        guard let context else { return }
        for page in pages {
            guard let url = URL(string: page.url) else { continue }
            let entry = HistoryEntry(url: url, title: page.title)
            entry.visitedAt = page.visitedAt
            entry.visitCount = page.visitCount
            context.insert(entry)
        }
        try? context.save()
        historyIndex.rebuild(from: context.container)
    }

    /// Pages matching what's typed, newest first: from the index in memory,
    /// or from the store in the moment after launch before it's built.
    func history(matching query: String, limit: Int) -> [HistoryIndex.Hit] {
        // Locked behind Face ID: nothing to suggest from until it's unlocked.
        guard let context, !PrivacyLock.shared.isLocked else { return [] }
        if historyIndex.isReady { return historyIndex.search(query, limit: limit) }
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: query.isEmpty ? nil : #Predicate {
                $0.title.localizedStandardContains(query) || $0.url.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map {
            HistoryIndex.Hit(url: $0.url, title: $0.title, visitCount: $0.visitCount, visitedAt: $0.visitedAt)
        }
    }

    /// What you open most, for a bar with nothing typed. The first moment after launch,
    /// before the index is built, it's simply the newest.
    func mostUsedHistory(limit: Int) -> [HistoryIndex.Hit] {
        guard !PrivacyLock.shared.isLocked else { return [] }
        return historyIndex.isReady ? historyIndex.mostUsed(limit: limit) : history(matching: "", limit: limit)
    }

    /// On every device: entry by entry, so the removal syncs.
    /// Pages visited since `since` (all of them by default), gone from history.
    func clearHistory(since: Date = .distantPast) {
        guard let context else { return }
        let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.visitedAt >= since })
        // One by one, so the deletions reach iCloud too (see README, "iCloud sync").
        ((try? context.fetch(descriptor)) ?? []).forEach(context.delete)
        try? context.save()
        historyIndex.rebuild(from: context.container)
    }
}

extension BrowserModel: BrowserTabDelegate {
    func tab(_ tab: BrowserTab, didFinishLoading url: URL, title: String) {
        // Went to another page while hiding (a swipe back): the mode was for that one.
        if tab.id == selectedID, hidingItems != nil { finishHidingItems() }
        offerApp(for: tab, url: url)
        // The bar's tab card shows this page, once it has had a moment to paint.
        if tab.id == selectedID {
            Task {
                try? await Task.sleep(for: .seconds(1))
                await tab.captureSnapshot()
            }
        }
        // Private pages leave nothing on disk, icons included.
        guard !tab.isPrivate else { return }
        if let webView = tab.webView {
            Task { await FaviconStore.shared.refresh(from: webView) }
        }
        // The spare web view for the next new tab, now that this page is in:
        // built a second after the last was taken, it landed mid-load.
        WebViewFactory.prewarm()
        guard let context, url.scheme?.hasPrefix("http") == true else { return }
        // Save open tabs as pages finish, so a force-quit or crash loses nothing.
        scheduleSave()

        let address = url.absoluteString
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.url == address })
        descriptor.fetchLimit = 1
        if let entry = try? context.fetch(descriptor).first {
            // Seen again within minutes (a reload, back and forward): not a new
            // visit, and not another record for iCloud to carry to every device.
            if entry.visitedAt.timeIntervalSinceNow > -300, title.isEmpty || entry.title == title { return }
            entry.visitedAt = .now
            entry.visitCount += 1
            if !title.isEmpty { entry.title = title }
            historyIndex.note(url: address, title: entry.title, visitCount: entry.visitCount, visitedAt: entry.visitedAt)
        } else {
            let entry = HistoryEntry(url: url, title: title)
            context.insert(entry)
            historyIndex.note(url: address, title: title, visitCount: 1, visitedAt: entry.visitedAt)
        }
        try? context.save()
    }

    func tab(_ tab: BrowserTab, says message: String) {
        showToast(message)
    }

    func tab(_ tab: BrowserTab, linkMenuFor url: URL) -> UIContextMenuConfiguration? {
        closePeek()
        dismissOffers()
        let page = BrowserTab(url: url, isPrivate: tab.isPrivate)
        if tab.isPrivate { PrivacyLock.shared.opened(page.id) }
        page.wake()
        peek = page
        let link = CleanLink.clean(url)
        let icon = { (name: String) in UIImage(named: "phosphor/\(name)") }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            LinkPreview(tab: page)
        }, actionProvider: { [weak self] _ in
            var actions = [
                UIAction(title: "Open in New Tab", image: icon("tab")) { _ in self?.openPeek(showing: true) },
                UIAction(title: "Open in Background", image: icon("tabs")) { _ in self?.openPeek(showing: false) },
            ]
            if !tab.isPrivate {
                actions.append(UIAction(title: "Open in Private Tab", image: icon("eyeClosed")) { _ in
                    self?.closePeek()
                    self?.open(url, inNewTab: true, isPrivate: true)
                })
            }
            var more: [UIAction] = []
            if !tab.isPrivate {
                more.append(UIAction(title: "Save for Later", image: icon("readLater")) { _ in self?.savePeekForLater() })
            }
            more.append(UIAction(title: "Copy Link", image: icon("link")) { _ in
                UIPasteboard.general.url = link
                CopiedLink.copiedHere(link)
                self?.showToast("Link copied")
            })
            more.append(UIAction(title: "Share", image: icon("share")) { _ in ShareSheet.present([link]) })
            return UIMenu(children: [UIMenu(options: .displayInline, children: actions),
                                     UIMenu(options: .displayInline, children: more)])
        })
    }

    func tabOnlyDownloaded(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.url = nil
        close(tab)
    }

    func tab(_ tab: BrowserTab, openedWindow webView: WKWebView, showing url: URL?) {
        let window = BrowserTab(url: url, isPrivate: tab.isPrivate)
        if tab.isPrivate { PrivacyLock.shared.opened(window.id) }
        window.opener = tab.id
        window.delegate = self
        window.take(webView)
        tabs.append(window)
        select(window)
        panel = .none
    }

    func tabClosedItself(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        let opener = tab.opener.flatMap { self.tab($0) }
        // Nothing worth reopening: the sign-in is over.
        tab.url = nil
        close(tab)
        if let opener { select(opener) }
    }

    func tabOpensPeek(_ tab: BrowserTab) {
        openPeek(showing: true)
    }

    func tabEndsPeek(_ tab: BrowserTab) {
        // A menu action runs just after the menu ends: give it the page first.
        let ending = peek
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if let ending, peek === ending { closePeek() }
        }
    }


    func tab(_ tab: BrowserTab, wantsNewTabWith url: URL) {
        open(url, inNewTab: true, isPrivate: tab.isPrivate)
    }

    /// As in Arc: a page reloaded again and again probably isn't working.
    /// When roko is answering its cookie pop-ups, offer to allow cookies there.
    func tabKeepsReloading(_ tab: BrowserTab) {
        guard tab.id == selectedID, let host = tab.url?.host(),
              ContentBlocker.shared.isEnabled(.cookies), !ContentBlocker.shared.isAllowed(host: host),
              !ContentBlocker.shared.isAllowed(host: host, category: .cookies),
              ConsentHandler.shared.acceptance(for: host) == nil,
              cookieOffersMade.insert(host).inserted else { return }
        cookieOffer = host
        cookieOfferTask?.cancel()
        cookieOfferTask = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { cookieOffer = nil }
        }
    }

    // MARK: Open in app

    private func offerApp(for tab: BrowserTab, url: URL) {
        // Whether the app is installed is asked of iOS last: it's a round trip
        // to LaunchServices, on every page of a site that has one.
        guard AppLinks.Mode.current == .offer, tab.id == selectedID, panel == .none,
              let app = AppLinks.app(for: url), !appOffersMade.contains(app.scheme),
              AppLinks.isInstalled(app), appOffersMade.insert(app.scheme).inserted else { return }
        appOffer = (app, url)
        appOfferTask?.cancel()
        appOfferTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { appOffer = nil }
        }
    }

    func openInApp() {
        guard let offer = appOffer else { return }
        appOffer = nil
        appOfferTask?.cancel()
        // The page you're on now, which may have moved on since the offer.
        let url = selectedTab?.url.flatMap { AppLinks.installedApp(for: $0) == offer.app ? $0 : nil } ?? offer.url
        Task {
            if await !AppLinks.open(url) { showProblem("\(offer.app.name) doesn't open this page") }
        }
    }

    #if DEBUG
    /// `-showOffer`: the cookie offer, to look at.
    func showCookieOfferForTesting() {
        cookieOffer = selectedTab?.url?.host() ?? "example.com"
    }
    #endif

    /// Gone as something else opens (the bar, a panel): not left behind it.
    func dismissOffers() {
        if cookieOffer != nil {
            cookieOffer = nil
            cookieOfferTask?.cancel()
        }
        // Hidden, not taken: opening the bar is how the link gets used, and
        // the bar lists it. (Taken here, it was gone from both places.)
        if copiedLinkOffer {
            copiedLinkOffer = false
            copiedLinkTask?.cancel()
        }
        if appOffer != nil {
            appOffer = nil
            appOfferTask?.cancel()
        }
    }

    func allowCookies() {
        guard let host = cookieOffer, let webView = selectedTab?.webView else { return }
        cookieOffer = nil
        cookieOfferTask?.cancel()
        Task { await ConsentHandler.shared.acceptNow(in: webView, host: host) }
        showToast("Cookies allowed on \(URL(string: "https://\(host)")?.displayHost ?? host)")
    }
}

enum ArchivePolicy: String, CaseIterable, Identifiable {
    case twelveHours, day, week, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twelveHours: "After 12 hours"
        case .day: "After a day"
        case .week: "After a week"
        case .never: "Never"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .never: .infinity
        }
    }

    static var current: ArchivePolicy {
        UserDefaults.standard.string(forKey: "archivePolicy").flatMap(ArchivePolicy.init) ?? .day
    }
}
