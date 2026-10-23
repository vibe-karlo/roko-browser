import SwiftData
import SwiftUI
import WebKit

/// The whole browser's state: tabs, which one is showing, and which panel is open.
@Observable
final class BrowserModel {
    enum Panel: Equatable {
        case none, command, tabs, tools, settings
    }

    enum CommandMode {
        case newTab, currentTab, privateTab
    }

    /// Live web views kept in memory; older tabs hibernate to a snapshot.
    static let liveTabLimit = 3

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedID: BrowserTab.ID?
    var panel: Panel = .none
    var commandPrefill = ""
    var commandMode: CommandMode = .newTab
    var isBarCollapsed = false
    var summary: SummaryModel?
    /// True while the summary's card stands in for the page, which hides
    /// underneath so the two never show at once.
    var summaryCoversPage = false
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    var browseForMe: BrowseForMeModel?
    var reader: ReaderModel?

    @ObservationIgnored private var context: ModelContext?

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }

    // MARK: Launch and persistence

    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        // Build one web view now so the restored tab takes it, then build the
        // spare for the next new tab once launch has settled, not during it.
        WebViewFactory.prewarm()
        restoreTabs()
        Task {
            await ContentBlocker.shared.prepare()
            LaunchClock.mark("blockerReady")
            // Only now start the restored page, so its very first requests are
            // already filtered. Until then its saved snapshot stands in.
            if let tab = selectedTab { select(tab) }
            try? await Task.sleep(for: .seconds(1.5))
            WebViewFactory.prewarm()
            // Pay the calculator's one-time setup (formatters, unit tables) now,
            // not on the first keystroke.
            _ = Calculator.answer("1 km + 1")
        }
        if tabs.isEmpty { panel = .command }
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

    func saveTabs() {
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
        defer { saveTabs() }
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

    func showCommandBar(prefill: String = "", mode: CommandMode = .newTab) {
        commandPrefill = prefill
        commandMode = mode
        panel = .command
    }

    /// Opens a URL from the command bar, honouring the mode it was opened in.
    func openFromCommandBar(_ url: URL) {
        switch commandMode {
        case .currentTab: open(url, inNewTab: selectedTab == nil)
        case .newTab: open(url, inNewTab: true)
        case .privateTab: open(url, inNewTab: true, isPrivate: true)
        }
    }

    /// Opens the full-screen summary. `fromScale` is how far a pinch had already
    /// shrunk the page, so the card continues from exactly there.
    /// The page as it was when a pinch began, taken then so the summary can
    /// open the instant the fingers lift.
    @ObservationIgnored private var pinchSnapshot: Task<UIImage?, Never>?

    func preparePinchSnapshot() {
        guard pinchSnapshot == nil, let tab = selectedTab else { return }
        pinchSnapshot = Task { await tab.viewportSnapshot() }
    }

    func cancelPinchSnapshot() {
        pinchSnapshot = nil
    }

    func summarize(fromScale: CGFloat = 1) {
        guard let tab = selectedTab, let webView = tab.webView, tab.url != nil else { return }
        let model = SummaryModel(title: tab.displayTitle, host: tab.url?.displayHost ?? "", snapshot: nil)
        model.startScale = fromScale
        let prepared = pinchSnapshot
        pinchSnapshot = nil
        Task {
            // The page as it is on screen, so it can shrink into the card.
            if let prepared { model.snapshot = await prepared.value }
            if model.snapshot == nil { model.snapshot = await tab.viewportSnapshot() ?? tab.snapshot }
            presentAfterPanelCloses { self.summary = model }
            await model.run(webView: webView)
        }
    }

    func openReader() {
        guard let tab = selectedTab, let webView = tab.webView else { return }
        let model = ReaderModel(host: tab.url?.displayHost ?? "")
        presentAfterPanelCloses { self.reader = model }
        Task { await model.load(from: webView) }
    }

    func browse(for query: String) {
        let model = BrowseForMeModel(query: query)
        presentAfterPanelCloses { self.browseForMe = model }
        Task { await model.run() }
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

    func isPinned(_ url: URL?) -> Bool {
        guard let url else { return false }
        return pins().contains { URL(string: $0.url)?.displayHost == url.displayHost }
    }

    func togglePin(for tab: BrowserTab) {
        guard let context, let url = tab.url else { return }
        if let existing = pins().first(where: { URL(string: $0.url)?.displayHost == url.displayHost }) {
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

    /// Opens a pinned site in its existing tab when there is one, Arc-style.
    func open(_ pin: Pin) {
        guard let url = URL(string: pin.url) else { return }
        if let tab = tabs.first(where: { $0.url?.displayHost == url.displayHost && !$0.isPrivate }) {
            select(tab)
            panel = .none
        } else {
            open(url, inNewTab: true)
        }
    }

    // MARK: History

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

    func clearHistory() {
        try? context?.delete(model: HistoryEntry.self)
        try? context?.save()
    }
}

extension BrowserModel: BrowserTabDelegate {
    func tab(_ tab: BrowserTab, didFinishLoading url: URL, title: String) {
        if let webView = tab.webView {
            Task { await FaviconStore.shared.refresh(from: webView) }
        }
        guard !tab.isPrivate, let context, url.scheme?.hasPrefix("http") == true else { return }
        // Save open tabs as pages finish, so a force-quit or crash loses nothing.
        saveTabs()

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

    func tab(_ tab: BrowserTab, wantsNewTabWith url: URL) {
        open(url, inNewTab: true, isPrivate: tab.isPrivate)
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
