import SwiftData
import SwiftUI
import WebKit

/// The whole browser's state: tabs, which one is showing, and which panel is open.
@Observable
final class BrowserModel {
    enum Panel: Equatable {
        case none, command, tabs, tools, settings, notifyMe, todos, today
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
    }

    /// Live web views kept in memory; older tabs hibernate to a snapshot.
    static let liveTabLimit = 3

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedID: BrowserTab.ID?
    var panel: Panel = .none
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
    var isBarCollapsed = false
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
            // Already on screen: nothing to offer.
            if let url, isCurrentPage(url) { return }
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
        copiedLinkOffer = false
        copiedLinkTask?.cancel()
        open(url, inNewTab: true)
    }
    var browseForMe: BrowseSession? {
        // An answer that's closed or replaced stops working on the spot:
        // nobody will read it, so it shouldn't keep searching or spending tokens.
        didSet { if oldValue !== browseForMe { oldValue?.cancel() } }
    }
    var reader: ReaderModel?

    @ObservationIgnored private var context: ModelContext?

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }

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
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relieveMemory() }
        }
        // Build one web view now so the restored tab takes it, then build the
        // spare for the next new tab once launch has settled, not during it.
        WebViewFactory.prewarm()
        restoreTabs()
        // A Notify Me notification opens its page.
        NotificationRouter.shared.open = { [weak self] url in
            // roko's own reminders open Today or To-do; Notify Me's open their page.
            switch url.absoluteString {
            case "roko://today": self?.panel = .today
            case "roko://todo": self?.panel = .todos
            default: self?.open(url, inNewTab: true)
            }
        }
        // Cookies accepted because a site needs them: say so, once per site.
        ConsentHandler.shared.onAccepted = { [weak self] host, _ in
            self?.showToast("Accepted cookies: \(URL(string: "https://\(host)")?.displayHost ?? host) needs them")
        }
        Task {
            await ContentBlocker.shared.prepare()
            LaunchClock.mark("blockerReady")
            // Only now start the restored page, so its very first requests are
            // already filtered. Until then its saved snapshot stands in.
            if let tab = selectedTab { select(tab) }
            try? await Task.sleep(for: .seconds(1.5))
            WebViewFactory.prewarm()
            await tidyUp()
            // Pay the calculator's one-time setup (formatters, unit tables) now,
            // not on the first keystroke.
            _ = Calculator.answer("1 km + 1")
        }
        if tabs.isEmpty { panel = .command }
    }

    /// Launch housekeeping, once things are quiet: pictures of tabs that are
    /// gone, and history older than 90 days, which would otherwise grow forever
    /// and slow every address-bar search.
    private func tidyUp() async {
        await BrowserTab.pruneSnapshots(keeping: Set(tabs.map(\.id)))
        guard let context else { return }
        let cutoff = Date.now.addingTimeInterval(-90 * 24 * 3600)
        // One by one rather than as a batch: history syncs, and the removal
        // has to reach iCloud like any other change.
        let old = (try? context.fetch(FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.visitedAt < cutoff }))) ?? []
        old.forEach(context.delete)
        try? context.save()
        mergeSyncedDuplicates()
    }

    /// Pages and pins that two devices added before hearing from each other.
    /// At most once an hour: it reads all of history.
    func mergeSyncedDuplicates() {
        guard Store.syncs, let context else { return }
        if let last = lastMerge, Date.now.timeIntervalSince(last) < 3600 { return }
        lastMerge = .now
        Store.mergeDuplicates(in: context)
    }
    @ObservationIgnored private var lastMerge: Date?

    /// iOS is short of memory: give back what can be rebuilt, before it has to
    /// close roko. The tab on screen is never touched.
    private func relieveMemory() {
        for tab in tabs where tab.id != selectedID {
            if tab.isLive {
                // Its fresh picture is still being written; the web view is the big saving.
                Task { await tab.hibernate() }
            } else {
                tab.releaseSnapshotMemory()
            }
        }
        WebViewFactory.dropPrewarmed()
        FaviconStore.shared.trimMemory()
    }

    private func restoreTabs() {
        guard let context else { return }
        let saved = (try? context.fetch(FetchDescriptor<SavedTab>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let cutoff = Date.now.addingTimeInterval(-ArchivePolicy.current.interval)

        for record in saved where record.lastActive > cutoff {
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

    func saveTabs() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let context else { return }
        try? context.delete(model: SavedTab.self)
        for (index, tab) in tabs.enumerated() where !tab.isPrivate {
            guard let url = tab.url else { continue }
            context.insert(SavedTab(tabID: tab.id, url: url.absoluteString, title: tab.title, order: index,
                                    lastActive: tab.lastActive, interactionState: tab.interactionState))
        }
        try? context.save()
    }

    // MARK: Tabs

    func select(_ tab: BrowserTab) {
        let previous = selectedTab
        // Into private browsing: say so, once, as it happens.
        if tab.isPrivate, previous?.isPrivate != true {
            showToast("Private tab: nothing is kept")
        }
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
        } else {
            let tab = BrowserTab(url: url, isPrivate: isPrivate)
            tab.delegate = self
            tabs.append(tab)
            select(tab)
        }
        panel = .none
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        Task {
            await tab.hibernate()
            tab.discardSnapshot()
        }
        tabs.remove(at: index)
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
        let live = tabs.filter { $0.isLive && $0.id != selectedID }
            .sorted { $0.lastActive > $1.lastActive }
        for tab in live.dropFirst(Self.liveTabLimit - 1) {
            await tab.hibernate()
        }
    }

    // MARK: Commands

    /// A brief confirmation above the bar, such as "Copied 3.11 mi".
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { toast = nil }
        }
    }

    func showTabs() {
        // Refresh the current tab's card while its page is still on screen.
        Task { await selectedTab?.captureSnapshot() }
        panel = .tabs
    }

    func showCommandBar(prefill: String = "", mode: CommandMode = .newTab,
                        context: LauncherContext = .web, over screen: Panel = .none) {
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
                if !(await VoiceInput.authorize()) { showToast("Allow the microphone and speech in Settings") }
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
            showCommandBar()
        } catch {
            showToast("Couldn't start listening")
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

    /// The launcher closed while listening: stop, and forget what was heard.
    func cancelVoice() {
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
        Task {
            let heard = await VoiceInput.shared.stop()
            voiceListening = false
            guard let heard, !heard.isEmpty else {
                if panel == .command { showToast("Didn't catch that") }
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

    func openReader() {
        guard let tab = selectedTab, let webView = tab.webView else { return }
        let model = ReaderModel(host: tab.url?.displayHost ?? "")
        presentAfterPanelCloses { self.reader = model }
        Task { await model.load(from: webView) }
    }

    func browse(for query: String) {
        let session = BrowseSession(question: query)
        presentAfterPanelCloses { self.browseForMe = session }
    }

    /// SwiftUI drops a sheet presented while another is still sliding away, so
    /// when a sheet panel is open, wait for it to finish closing first.
    private func presentAfterPanelCloses(_ present: @escaping () -> Void) {
        let wasSheet = panel == .settings
        panel = .none
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
    func forget(_ url: URL, wholeSite: Bool = false) {
        guard let context else { return }
        let host = url.displayHost
        let all = (try? context.fetch(FetchDescriptor<HistoryEntry>())) ?? []
        for entry in all where wholeSite ? URL(string: entry.url)?.displayHost == host : entry.url == url.absoluteString {
            context.delete(entry)
        }
        try? context.save()
    }

    func history(matching query: String, limit: Int) -> [HistoryEntry] {
        guard let context else { return [] }
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: query.isEmpty ? nil : #Predicate {
                $0.title.localizedStandardContains(query) || $0.url.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// On every device: entry by entry, so the removal syncs.
    func clearHistory() {
        guard let context else { return }
        ((try? context.fetch(FetchDescriptor<HistoryEntry>())) ?? []).forEach(context.delete)
        try? context.save()
    }
}

extension BrowserModel: BrowserTabDelegate {
    func tab(_ tab: BrowserTab, didFinishLoading url: URL, title: String) {
        // Private pages leave nothing on disk, icons included.
        guard !tab.isPrivate else { return }
        if let webView = tab.webView {
            Task { await FaviconStore.shared.refresh(from: webView) }
        }
        guard let context, url.scheme?.hasPrefix("http") == true else { return }
        // Save open tabs as pages finish, so a force-quit or crash loses nothing.
        scheduleSave()

        let address = url.absoluteString
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.url == address })
        descriptor.fetchLimit = 1
        if let entry = try? context.fetch(descriptor).first {
            entry.visitedAt = .now
            entry.visitCount += 1
            if !title.isEmpty { entry.title = title }
        } else {
            context.insert(HistoryEntry(url: url, title: title))
        }
        try? context.save()
    }

    func tab(_ tab: BrowserTab, says message: String) {
        showToast(message)
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
