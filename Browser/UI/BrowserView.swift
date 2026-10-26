import SwiftData
import SwiftUI

struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var barTop: CGFloat = 0

    var body: some View {
        @Bindable var browser = browser

        ZStack {
            // Behind the page: the site's top colour in the status-bar strip
            // only (as in Safari), and its own background below, so no header
            // colour ever shows at the bottom of the screen.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    (browser.summaryCoversPage && browser.summary?.isClosing != true ? Theme.canvas : browser.selectedTab?.topColor.map(Color.init) ?? Theme.canvas)
                        .frame(height: proxy.safeAreaInsets.top)
                    (browser.summaryCoversPage && browser.summary?.isClosing != true ? Theme.canvas : browser.selectedTab?.bottomColor.map(Color.init) ?? Theme.canvas)
                }
                .ignoresSafeArea()
            }
            .animation(.easeOut(duration: 0.2), value: browser.selectedTab?.topColor)

            if let tab = browser.selectedTab {
                WebViewHost(
                    tab: tab,
                    barTop: barTop,
                    onSummarize: { browser.summarize(from: $0) },
                    onPreview: { showing in
                        if browser.pageBecomingSummary != showing { browser.pageBecomingSummary = showing }
                    },
                    onScrollDirection: { down in
                        if browser.isBarCollapsed != down { browser.isBarCollapsed = down }
                    })
                    .opacity(browser.summaryCoversPage ? 0 : 1)
                    // Down to the bottom edge, under the floating bar. The
                    // keyboard too: WebKit makes room for it on its own, and
                    // shrunk by SwiftUI as well, the page stopped short of the
                    // keyboard while typing into a form.
                    .ignoresSafeArea(edges: .bottom)

                // A restored tab shows its last snapshot until its page is live.
                if !tab.isLive, let snapshot = tab.snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)
                }

                if let error = tab.loadError {
                    LoadErrorView(message: error) { if let url = tab.url { tab.load(url) } }
                }
            } else {
                StartView()
                    // The bar floats over the page; the start page keeps clear of it.
                    .safeAreaPadding(.bottom, Theme.barHeight + 4)
            }
        }
        // Floating over the page rather than inset below it, as in Safari: the
        // page runs to the bottom edge, bar or no bar. Laid out below the page,
        // it left a strip of the page's background under it, and when the bar
        // folded away while scrolling, a blank band above the home indicator.
        // The page learns which strip the bar covers from barTop (WebViewHost).
        .overlay(alignment: .bottom) {
            // The command bar takes the bar's place rather than stacking on top of it.
            BottomBar()
                .opacity(browser.launcherShown || browser.panel == .tabs || browser.pageBecomingSummary ? 0 : 1)
                // Faded, not folded: folding changes the page's insets, which stops a pull dead.
                .animation(.easeOut(duration: 0.2), value: browser.pageBecomingSummary)
                // Out as the launcher opens out of it, back as it closes, at its pace.
                .animation(.launcher, value: browser.launcherShown)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
                // Typing into a page, the keyboard covers the bar, as in Safari;
                // risen above it, the bar sat on top of the form being filled in.
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .overlay {
            if browser.panel == .tabs {
                // Arrives from below; leaves upward, continuing the pull that uncovers the page.
                // Full screen: its own bottom row replaces the bar it would sit above.
                TabStackView()
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.asymmetric(insertion: .move(edge: .bottom),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .overlay {
            if browser.panel == .tools {
                BottomPanel { browser.panel = .none } content: { ToolsSheet() }
            }
        }
        .overlay {
            if browser.panel == .notifyMe, let tab = browser.selectedTab {
                BottomPanel { browser.panel = .none } content: { NotifyMeSheet(tab: tab) }
            }
        }
        .overlay {
            if browser.panel == .today || browser.panel == .command && browser.launcherReturn == .today {
                TodayView()
                    .transition(.move(edge: .bottom))
            }
        }
        .overlay {
            if browser.panel == .todos || browser.panel == .command && browser.launcherReturn == .todos {
                // Full screen, rising from the bar like Browse for Me.
                TodoView()
                    .transition(.move(edge: .bottom))
            }
        }
        .overlay {
            if let session = browser.browseForMe {
                // Full screen, rising from the bar where the question was asked.
                BrowseForMeView(session: session)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(duration: 0.42, bounce: 0.06), value: browser.browseForMe?.id)
        .overlay {
            if let summary = browser.summary {
                // Full screen; it animates the page into its card itself.
                SummaryView(model: summary)
                    .transition(.identity)
            }
        }
        .overlay {
            if browser.panel == .command {
                // Over whatever screen it was opened from, which stays under it.
                CommandBarView()
                    // It animates itself: its field grows out of the bar's capsule.
                    .transition(.identity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = browser.toast {
                Text(toast)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .barSurface(cornerRadius: 14)
                    .padding(.bottom, Theme.barHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if browser.cookieOffer != nil, browser.panel == .none {
                // After a few reloads: the page may be broken by its cookie pop-up's answer.
                HStack(spacing: 14) {
                    Text("Page not working?")
                        .font(.system(size: 15, weight: .medium))
                    Button("Allow cookies") { browser.allowCookies() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .lineLimit(1)
                .padding(.leading, 18)
                .padding(.trailing, 16)
                .barSurface(cornerRadius: 14)
                .padding(.bottom, Theme.barHeight + 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.cookieOffer)
        .overlay(alignment: .bottom) {
            // Never over the page menu or another panel opened while it showed.
            if browser.copiedLinkOffer, browser.cookieOffer == nil, browser.panel == .none {
                // Opening roko with a link just copied, here or on a Mac. Built
                // like the cookie offer: what it is, then one word to act.
                HStack(spacing: 14) {
                    if let url = browser.copiedLinkURL {
                        HStack(spacing: 10) {
                            SiteIcon(host: url.displayHost, size: 18)
                            Text(url.shortDisplay)
                                .font(.system(size: 15, weight: .medium))
                        }
                        Button("Open") { browser.openCopiedLink(url) }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    } else {
                        // Spaced so "Paste" sits as "Allow cookies" does.
                        HStack(spacing: 14 - PasteControl.inset) {
                            Text("Link you copied")
                                .font(.system(size: 15, weight: .medium))
                            PasteControl { browser.openCopiedLink($0) }
                        }
                    }
                }
                .lineLimit(1)
                .padding(.leading, browser.copiedLinkURL == nil ? 18 : 14)
                .padding(.trailing, browser.copiedLinkURL == nil ? 16 - PasteControl.inset : 16)
                .barSurface(cornerRadius: 14)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.barHeight + 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.copiedLinkOffer)
        .modifier(CopiedLinkWatch(browser: browser))
        // Handoff: continue this page on a Mac or iPad.
        .userActivity(NSUserActivityTypeBrowsingWeb, element: browser.handoffPage) { page, activity in
            activity.webpageURL = page.url
            activity.title = page.title
            activity.isEligibleForHandoff = true
        }
        .background(StatusBarStyler(style: statusBarStyle))
        // Every toast confirms something done (copied, pinned, translating): a tick to feel it.
        .sensoryFeedback(.impact(weight: .light), trigger: browser.toast) { _, toast in toast != nil }
        .animation(.snappy(duration: 0.25), value: browser.toast)
        .animation(.snappy(duration: 0.3), value: browser.panel)
        .sheet(isPresented: panelBinding(.settings)) {
            SettingsView()
        }
        .sheet(item: $browser.reader) { model in
            ReaderView(model: model)
        }
        .onAppear {
            LaunchClock.mark("firstAppear")
            browser.start(context: context)
        }
        #if DEBUG
        .task {
            if Benchmark.isRequested { await Benchmark.run() }
            if !BrowseProbe.questions.isEmpty { await BrowseProbe.run() }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                browser.saveTabs()
                WatchScheduler.schedule(in: context)
                TodayModel.scheduleMorningRefresh()
                DailyReminders.update(in: context)
            }
            if phase == .active {
                checkWatches(after: .seconds(2))
                browser.mergeSyncedDuplicates()
            }
        }
        // Launch: Notify Me catches up once the first page has had its moment.
        .task { checkWatches(after: .seconds(4)) }
        // Coming back to the app always shows the bar; scrolling hides it again.
        // UIKit's own signal: it arrives whatever wraps the SwiftUI scene.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // To-dos ticked off in a widget meanwhile.
            WidgetBridge.applyTicks()
            if browser.isBarCollapsed { browser.isBarCollapsed = false }
            // The first time on a new day: Today first.
            if TodayModel.shouldOpenNow(), browser.panel == .none, browser.summary == nil, browser.browseForMe == nil {
                browser.panel = .today
                return
            }
            // Back with a link just copied, perhaps on a Mac: offer it.
            CopiedLink.arrived()
            browser.offerCopiedLinkIfFresh()
        }
        // So does coming back from a summary, an answer or the reader: the
        // pull or scroll that led there may have folded it away.
        .onChange(of: browser.summary == nil && browser.browseForMe == nil && browser.reader == nil) { _, backOnPage in
            if backOnPage, browser.isBarCollapsed { browser.isBarCollapsed = false }
        }
    }

    /// With roko open, Notify Me checks whatever is due, including the pages
    /// that need their scripts run, which the background can't do.
    private func checkWatches(after delay: Duration) {
        let container = context.container
        Task {
            try? await Task.sleep(for: delay)
            #if DEBUG
            let force = ProcessInfo.processInfo.arguments.contains("-checkWatches")
            #else
            let force = false
            #endif
            await Watcher.runDue(in: container, inBackground: false, force: force)
        }
    }

    /// Text that reads on whatever is behind the status bar.
    private var statusBarStyle: UIStatusBarStyle {
        // The summary and Browse for Me sit on the app's own canvas.
        if browser.summary != nil || browser.browseForMe != nil || browser.panel == .todos || browser.panel == .today {
            return .default
        }
        if browser.panel == .tabs { return .lightContent }  // the switcher is always dark
        guard let color = browser.selectedTab?.topColor else { return .default }
        return color.isLight ? .darkContent : .lightContent
    }

    private func panelBinding(_ panel: BrowserModel.Panel) -> Binding<Bool> {
        Binding(
            get: { browser.panel == panel },
            set: { if !$0, browser.panel == panel { browser.panel = .none } })
    }
}

private struct LoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("This page didn't load")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

/// A panel that rises from the bottom edge and sits flush with it: rounded
/// top corners, square bottom ones, running under the home indicator. Tap
/// outside or drag it down to close.
private struct BottomPanel<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: Content
    @State private var shown = false
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            if shown {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Theme.faintInk.opacity(0.6))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                    content
                        .frame(maxHeight: 640)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                        .fill(Theme.panel)
                        .ignoresSafeArea(edges: .bottom)
                }
                .offset(y: max(0, drag))
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                            close()
                        } else {
                            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { drag = 0 }
                        }
                    })
                .transition(.move(edge: .bottom))
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.12)) { shown = true } }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.22)) { shown = false } completion: { dismiss() }
    }
}

/// Notes the clipboard as roko leaves, so only a link copied elsewhere is
/// offered on its return; and takes the offer away once you read on (scrolling
/// folds the bar).
private struct CopiedLinkWatch: ViewModifier {
    let browser: BrowserModel

    func body(content: Content) -> some View {
        content
            .onChange(of: browser.isBarCollapsed) { _, collapsed in
                if collapsed { browser.dismissCopiedLink() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                CopiedLink.left()
            }
    }
}
