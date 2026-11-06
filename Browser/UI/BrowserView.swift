import Network
import SwiftData
import SwiftUI

struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// How many times the app has become active: the first is launch itself.
    @State private var activations = 0
    @State private var barTop: CGFloat = 0
    /// Where the band under the page starts on screen.
    @State private var bandTop: CGFloat = 0
    @State private var bandHeight: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.fold) private var fold
    @Environment(\.propped) private var propped
    /// Once it's been dragged, the lower half's hint has done its job.
    @State private var trackpadUsed = false
    /// The strip beside the page, turned sideways, where the bar stands upright.
    /// Both sides' insets: held upright, only a Duo has any, for its clock.
    @State private var sideInsets: CGFloat = 0

    var body: some View {
        @Bindable var browser = browser

        let page = ZStack {
            // Behind the page: the site's top colour in the status-bar strip
            // only (as in Safari), and its own background below, so no header
            // colour ever shows at the bottom of the screen.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    (browser.summaryCoversPage && browser.summary?.isClosing != true ? Theme.canvas : browser.topTab?.topColor.map(Color.init) ?? Theme.canvas)
                        .frame(height: proxy.safeAreaInsets.top)
                    (browser.summaryCoversPage && browser.summary?.isClosing != true ? Theme.canvas : browser.selectedTab?.bottomColor.map(Color.init) ?? Theme.canvas)
                }
                .ignoresSafeArea()
            }
            .animation(.easeOut(duration: 0.2), value: browser.topTab?.topColor)

            if splitSideways || splitBesideClock || besideFold != nil {
                Color.black.ignoresSafeArea()
            }

            // A shut Duo with its clock at the side: the band's colour runs on up the
            // clock's strip, one surface around the page, not a dark band beside a page-coloured strip.
            if bandWrapsClock {
                BandGround(color: browser.selectedTab?.topColor).ignoresSafeArea()
            }

            // Propped open, black from the fold down, for the bar to lie on.
            // From a little above it, so the page's round corners show black.
            if let fold, standsOnFold {
                GeometryReader { proxy in
                    let top = proxy.frame(in: .global).minY
                    ZStack {
                        Color.black.padding(.top, fold.minY - top - 20)
                        // The empty half scrolls the page standing above it.
                        if let tab = browser.selectedTab {
                            PageTrackpad(tab: tab) { trackpadUsed = true }
                                .overlay {
                                    if !trackpadUsed {
                                        Text("Drag here to scroll the page")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.white.opacity(0.45))
                                            .padding(.bottom, Theme.barHeight)
                                            .allowsHitTesting(false)
                                            .transition(.opacity)
                                    }
                                }
                                .animation(.easeOut(duration: 0.3), value: trackpadUsed)
                                .padding(.top, fold.maxY - top)
                        }
                    }
                }
                .ignoresSafeArea()
            }

            if browser.selectedTab != nil {
                // One layout whatever is on screen, so a page is never shown by
                // two at once (a layout on its way out took its page with it).
                // Something playing in another tab: the page lifts into a card
                // and the player sits in the dark band under it (after Lens).
                // The bar lives in the band too, under the live row.
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        pages
                            // A split's panes are laid out to the space they have, with lists
                            // that must reach their last row: it stops at the band.
                            .padding(.bottom, splitHalves != nil && barInBand && showsBand ? bandHeight : 0)
                            .clipShape(RoundedRectangle(cornerRadius: besideFold != nil ? 16 : 0))
                            .padding(.leading, besideFold?.maxX ?? 0)
                            // Propped open, the page ends at the fold.
                            .frame(height: standsOnFold ? fold.map { max($0.minY - proxy.frame(in: .global).minY, 0) } : nil)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: sideways && barInBand ? 22 : 0,
                                                              bottomLeadingRadius: standsOnFold ? 16 : showsBand && !barInBand ? 22 : sideways && !showsBand ? 22 : 0,
                                                              bottomTrailingRadius: standsOnFold ? 16 : showsBand && !barInBand ? 22 : bandWrapsClock && !showsBand ? 22 : 0,
                                                              topTrailingRadius: bandWrapsClock ? 22 : 0))
                            .frame(maxHeight: .infinity, alignment: .top)
                        if showsBand && !barInBand {
                            band(bottomInset: proxy.safeAreaInsets.bottom)
                        }
                    }
                    // The page doesn't resize as the bar folds: the band slides over it and
                    // draws its rounded foot, and the page learns what's covered from bandTop.
                    // Animating its frame told every site it had resized, a dozen times a fold.
                    .overlay(alignment: .bottom) {
                        if showsBand && barInBand {
                            band(bottomInset: proxy.safeAreaInsets.bottom)
                                .background(alignment: .top) {
                                    BandGround(color: browser.selectedTab?.topColor)
                                        .clipShape(BandFloor())
                                        .padding(.top, -BandFloor.lip)
                                        .allowsHitTesting(false)
                                }
                                .overlay(alignment: .top) {
                                    ZStack {
                                        CardEdgeLip(radius: BandFloor.lip)
                                        CardEdgeProgress(tab: browser.selectedTab, radius: BandFloor.lip)
                                    }
                                    .frame(height: BandFloor.lip)
                                    .offset(y: -BandFloor.lip)
                                    .allowsHitTesting(false)
                                }
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    bandTop = $0.minY
                                    bandHeight = $0.height
                                }
                                .transition(.move(edge: .bottom))
                        }
                    }
                    // Only below: the status bar's strip keeps the page's colour.
                    .background { (showsBand && !barInBand ? Color.black : Color.clear).ignoresSafeArea(edges: .bottom) }
                    .ignoresSafeArea(edges: .bottom)
                    .animation(.snappy(duration: 0.3), value: browser.liveItems.isEmpty)
                    .animation(.snappy(duration: 0.25), value: browser.bandShowsStrip)
                    .animation(.snappy(duration: 0.3), value: standsOnFold)
                    .animation(.snappy(duration: 0.28), value: browser.isBarCollapsed)
                }
                // Typing into a page, the keyboard covers the band, as it does the floating
                // bar: its padding reads the safe area, which would lift it over the keyboard.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Turned sideways the page is a card with the band's colour around it, clear of
                // the Dynamic Island on one side and the same on the other: left to the web view's
                // own insets, a page could sit against one edge with a strip down the other.
                // On a Duo, open or shut, the clock runs down the side: the page keeps clear of it.
                .ignoresSafeArea(edges: sideways || clockBeside ? [] : .horizontal)
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
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: { sideInsets = $0 }
        .overlay(alignment: .bottom) {
            // The command bar takes the bar's place rather than stacking on top of it.
            HStack(spacing: 0) {
                if closesBeside && !browser.isBarCollapsed {
                    // Back to the answer or the list alone, beside the bar.
                    Button { browser.closeBeside() } label: {
                        Glyph(.close, size: 16, weight: 2)
                            .frame(width: Theme.barHeight + 8, height: Theme.barHeight + 8)
                            .barSurface(cornerRadius: (Theme.barHeight + 8) / 2)
                            .contentShape(.circle)
                    }
                    .buttonStyle(GlyphButtonStyle())
                    .padding(.leading, Theme.gutter)
                    .padding(.bottom, 4)
                    .transition(.opacity)
                    .accessibilityLabel("Close this page")
                }
                // Under a page, the bar is in the band.
                if !barInBand { BottomBar() }
            }
                .animation(.snappy(duration: 0.28), value: browser.isBarCollapsed)
                // On an open Duo the normal bar, at a bar's width, not stretched
                // across the screen. Bent, to one side of the bend; beside an
                // answer or a list, on the page's side; in a split, under the page it works.
                .frame(maxWidth: uprightFold != nil ? 480 : nil)
                .staysWithBar(browser)
                .animation(.snappy(duration: 0.28), value: browser.barSide)
                .ignoresSafeArea(.container, edges: uprightFold != nil ? .horizontal : [])
                .opacity(browser.splitList != nil ? 0 : 1)
                .allowsHitTesting(browser.splitList == nil)
                .opacity(browser.launcherShown || browser.panel == .tabs || browser.pageBecomingSummary || browser.hidingItems != nil ? 0 : 1)
                .allowsHitTesting(browser.hidingItems == nil)
                // Faded, not folded: folding changes the page's insets, which stops a pull dead.
                .animation(.easeOut(duration: 0.2), value: browser.pageBecomingSummary)
                // Out as the launcher opens out of it, back as it closes, at its pace.
                .animation(.launcher, value: browser.launcherShown)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
                // Typing into a page, the keyboard covers the bar, as in Safari;
                // risen above it, the bar sat on top of the form being filled in.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Above the player's band when there is one, where the bar still floats.
                .padding(.bottom, showsPlayer && !barInBand ? LiveBand.height(minimized: browser.bandShowsStrip) : 0)
                .animation(.snappy(duration: 0.3), value: showsPlayer)
        }
        .overlay {
            if browser.panel == .tabs || browser.panel == .command && browser.launcherReturn == .tabs {
                // Arrives from below; leaves upward, continuing the pull that uncovers the page.
                // Full screen: its own bottom row replaces the bar it would sit above.
                TabStackView()
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
            if browser.panel == .downloads {
                BottomPanel { browser.panel = .none } content: { DownloadsSheet() }
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
            if browser.panel == .todos || browser.panel == .command && browser.launcherReturn == .todos, browser.splitList == nil {
                // Full screen, rising from the bar like Browse for Me.
                TodoView()
                    .transition(.move(edge: .bottom))
            }
        }
        .overlay {
            if browser.panel == .shopping, browser.splitList == nil {
                ShoppingView()
                    .transition(.move(edge: .bottom))
            }
        }
        .modifier(ReadLaterScreens(browser: browser, besideFold: besideFold))
        .overlay {
            if let session = browser.browseForMe {
                // Full screen, rising from the bar where the question was asked.
                BrowseForMeView(session: session)
                    .besideFold(besideFold, hidden: browser.panel == .tabs)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(duration: 0.42, bounce: 0.06), value: browser.browseForMe?.id)
        .animation(.snappy(duration: 0.32), value: browser.pageBeside)
        .overlay {
            if let summary = browser.summary {
                if besideFold != nil {
                    // On an open Duo the page has no need to shrink: it stays, live, across the fold.
                    SummaryBesideView(model: summary)
                        .besideFold(besideFold, hidden: browser.panel == .tabs)
                        .transition(.move(edge: .leading))
                } else {
                    // Full screen; it animates the page into its card itself.
                    SummaryView(model: summary)
                        .transition(.identity)
                }
            }
        }
        screens(offers(page))
    }

    /// The launcher and the offers above the bar. Apart from `body` so neither
    /// is one expression the type checker gives up on in a Debug build.
    private func offers<Content: View>(_ page: Content) -> some View {
        page
        .overlay {
            if browser.panel == .command {
                // Over whatever screen it was opened from, which stays under it.
                CommandBarView()
                    // It animates itself: its field grows out of the bar's capsule.
                    .transition(.identity)
            }
        }
        .modifier(CookScreen(browser: browser))
        .overlay(alignment: .bottom) {
            if let toast = browser.toast {
                Text(toast)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .barSurface(cornerRadius: 14)
                    .compositingGroup()
                    .padding(.bottom, Theme.barHeight + 20 + playerLift)
                    // Never across the bend of an open Duo.
                    .staysWithBar(browser)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let offer = browser.undoOffer {
                HStack(spacing: 14) {
                    Text(offer.text)
                        .font(.system(size: 15, weight: .medium))
                    Button("Undo") { browser.takeUndo() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .lineLimit(1)
                .padding(.leading, 18)
                .padding(.trailing, 16)
                .barSurface(cornerRadius: 14)
                .compositingGroup()
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.barHeight + 20 + playerLift)
                .staysWithBar(browser)
                .id(offer.id)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.undoOffer?.id)
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
                // One piece: text and box arrive and leave together.
                .compositingGroup()
                .padding(.bottom, Theme.barHeight + 20 + playerLift)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.cookieOffer)
        .overlay(alignment: .bottom) {
            if let hidden = browser.hidingItems {
                HideItemsBar(hidden: hidden)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.hidingItems != nil)
        .overlay(alignment: .bottom) {
            // Never over the page menu or another panel opened while it showed.
            if browser.copiedLinkOffer, browser.cookieOffer == nil, browser.panel == .none, let url = browser.copiedLinkURL {
                // Opening roko with a link just copied, here or on a Mac. Built
                // like the cookie offer: what it is, then one word to act.
                HStack(spacing: 14) {
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
                }
                .lineLimit(1)
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .barSurface(cornerRadius: 14)
                .compositingGroup()
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.barHeight + 20 + playerLift)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.copiedLinkOffer)
        .overlay(alignment: .bottom) {
            // A page whose app you have: built like the copied-link offer.
            if let offer = browser.appOffer, browser.cookieOffer == nil, !browser.copiedLinkOffer, browser.panel == .none {
                HStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Glyph(.openApp, size: 18)
                        Text(offer.app.name)
                            .font(.system(size: 15, weight: .medium))
                    }
                    Button("Open in app") { browser.openInApp() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .lineLimit(1)
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .barSurface(cornerRadius: 14)
                .compositingGroup()
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.barHeight + 20 + playerLift)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .animation(.snappy(duration: 0.3), value: browser.appOffer?.url)
    }

    /// The screens over the page, and the scene's plumbing.
    private func screens<Content: View>(_ page: Content) -> some View {
        page
        .modifier(PageExtras(browser: browser, showsPlayer: showsPlayer, playerLift: playerLift))
        .modifier(CopiedLinkWatch(browser: browser))
        .modifier(WelcomeCover(browser: browser))
        // Handoff: continue this page on a Mac or iPad.
        .userActivity(NSUserActivityTypeBrowsingWeb, element: browser.handoffPage) { page, activity in
            activity.webpageURL = page.url
            activity.title = page.title
            activity.isEligibleForHandoff = true
        }
        .background(StatusBarStyler(style: statusBarStyle, hidden: hidesClockOverPage))
        // Every toast confirms something done (copied, pinned, translating): a tick to feel it.
        .sensoryFeedback(.impact(weight: .light), trigger: browser.toast) { _, toast in toast != nil }
        .animation(.snappy(duration: 0.25), value: browser.toast)
        .animation(.snappy(duration: 0.3), value: browser.panel)
        .sheet(isPresented: panelBinding(.settings)) {
            SettingsView()
        }
        .modifier(ReaderScreens(browser: browser, asBook: uprightFold != nil))
        .onChange(of: uprightFold != nil, initial: true) { _, upright in browser.uprightFoldOpen = upright }
        .onChange(of: barInBand, initial: true) { _, inBand in browser.barInBand = inBand }
        .onAppear {
            LaunchClock.mark("firstAppear")
            browser.start(context: context)
        }
        #if DEBUG
        .task {
            if Benchmark.isRequested { await Benchmark.run() }
            if !BrowseProbe.questions.isEmpty { await BrowseProbe.run() }
            if TopStoriesProbe.isRequested { await TopStoriesProbe.run() }
            if ProcessInfo.processInfo.arguments.contains("-showOffer") {
                try? await Task.sleep(for: .seconds(4))
                browser.showCookieOfferForTesting()
            }
            if ShoppingSeed.isRequested {
                ShoppingSeed.run(in: context)
                browser.panel = .shopping
            }
            let arguments = ProcessInfo.processInfo.arguments
            // `-domProbe <script>`: run on the open tab every 5 seconds, for looking
            // at a page as roko's web view has it (a cookie pop-up no rule finds).
            if let at = arguments.firstIndex(of: "-domProbe"), at + 1 < arguments.count {
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(5))
                    let webView = browser.selectedTab?.webView
                    let page = try? await webView?.evaluateJavaScript(arguments[at + 1])
                    let probe = arguments.firstIndex(of: "-domProbeConsent").map { arguments[$0 + 1] } ?? arguments[at + 1]
                    let consent = try? await webView?.evaluateJavaScript(probe, in: nil, contentWorld: ConsentHandler.world)
                    print("DOM \(browser.selectedTab?.url?.host() ?? "-") page \(page.map { "\($0)" } ?? "nil") consent \(consent.map { "\($0)" } ?? "nil")")
                }
            }
            // `-pageLines <url>`: the page as Notify Me reads it.
            if let at = arguments.firstIndex(of: "-pageLines"), at + 1 < arguments.count, let url = URL(string: arguments[at + 1]) {
                let lines = await PageLines.fetch(url) ?? []
                print("LINES \(lines.count), thin \(PageLines.isThin(lines))\n" + lines.prefix(6).joined(separator: "\n"))
            }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                browser.saveTabs()
                WatchScheduler.schedule(in: context)
                TodayModel.scheduleMorningRefresh()
                FeedStore.scheduleRefresh()
                DailyReminders.update(in: context)
            }
            if phase == .active {
                checkWatches(after: .seconds(2))
                // Reads all of history on the main thread: not while the first page is coming in.
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    browser.mergeSyncedDuplicates()
                }
            }
        }
        // Launch: Notify Me catches up once the first page has had its moment.
        .task { checkWatches(after: .seconds(4)) }
        // Coming back to the app always shows the bar; scrolling hides it again.
        // UIKit's own signal: it arrives whatever wraps the SwiftUI scene.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // To-dos ticked off in a widget meanwhile, and changes from other devices.
            WidgetBridge.applyTicks()
            activations += 1
            // Launch itself did these a moment ago.
            if activations > 1 {
                WidgetBridge.update()
                TodoAlerts.update()
                browser.refreshLive()
                browser.historyIndex.rebuild(from: context.container, ifOlderThan: 300)
            }
            if browser.isBarCollapsed { browser.isBarCollapsed = false }
            // The first time on a new day: Today first.
            if !browser.showsOnboarding, TodayModel.shouldOpenNow(), browser.panel == .none, browser.summary == nil, browser.browseForMe == nil, !browser.linkJustArrived {
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

    /// The mini player shows over the page and the bar, not over a panel or a screen of roko's own.
    /// Turned sideways on a page: the bar leaves the bottom for the strip at the side.
    /// Not on an open Duo: the page fills the screen there, with the normal bar over it.
    private var sideways: Bool {
        verticalSizeClass == .compact && uprightFold == nil && browser.selectedTab != nil
    }

    private var splitSideways: Bool { sideways && splitHalves != nil }

    /// On an open Duo in landscape the clock's strip runs down the side, and over a
    /// page filling the screen it would sit on the site's own menu. So the clock
    /// goes while a page is on screen, and comes back with roko's own full screens.
    private var hidesClockOverPage: Bool {
        guard uprightFold != nil, browser.selectedTab != nil, browser.reader == nil, browser.cook == nil,
              !browser.showsOnboarding, besideFold != nil || browser.browseForMe == nil else { return false }
        return [.none, .tools, .downloads, .notifyMe].contains(browser.panel)
    }

    /// The fold when it runs top to bottom: an open Duo in landscape.
    private var uprightFold: CGRect? {
        fold.flatMap { $0.height > $0.width ? $0 : nil }
    }

    /// A source opened from an answer stands beside it, a side of the fold each.
    private var besideFold: CGRect? {
        browser.screenBeside ? uprightFold : nil
    }

    /// The tab beside came from the answer or the list, and has a way back to them.
    private var closesBeside: Bool { browser.pageBeside && besideFold != nil }

    /// Propped open on one page: it stands above the fold, the bar lies below.
    /// A split already parts at the fold, a page on each half.
    private var standsOnFold: Bool {
        propped && browser.selectedTab != nil && splitHalves == nil
    }

    /// A Duo with its clock at the side, not turned the way the bar moves there.
    private var clockBeside: Bool { !sideways && sideInsets > 0 && uprightFold == nil }

    /// Split with the clock at the side: black runs on under it. Turned, with
    /// the clock on top, that band keeps the top page's colour.
    private var splitBesideClock: Bool { clockBeside && splitHalves != nil }

    private var showsPlayer: Bool {
        !browser.liveItems.isEmpty && browser.selectedTab != nil
    }

    /// The bar lives in the band under a page: on a phone either way up and on
    /// a Duo open, flat or bent, where the band runs across and its controls keep
    /// off the bend. Split or with a screen beside the page, a Duo keeps the bar on
    /// one half, floating.
    private var barInBand: Bool {
        guard browser.selectedTab != nil, !standsOnFold else { return false }
        return uprightFold == nil || (besideFold == nil && splitHalves == nil)
    }

    /// The band under the page: the bar while it isn't folded away, and what's live.
    private var showsBand: Bool {
        return showsPlayer || barInBand && !browser.isBarCollapsed
    }

    private var bandWrapsClock: Bool { (clockBeside || sideways) && barInBand }

    /// On a wide screen, a bar's width in the middle of the band, not stretched across it.
    private var bandBarWidth: CGFloat? { uprightFold != nil || sideways ? 480 : nil }

    /// With the band up, it covers the page from its top; with it gone, nothing is covered.
    private var coveredFrom: CGFloat { showsBand ? bandTop : .greatestFiniteMagnitude }

    /// What's live and the bar, down into the home indicator's strip: on the dark band
    /// it has room, and keeping clear of all of it left a tall empty gap. The capsule stays
    /// 8 clear of the indicator: closer, it reads as a second pill and crowds the swipe home. With the bar
    /// folded the row is last, and its dots need to clear the indicator.
    private func band(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !browser.liveItems.isEmpty {
                LiveBand()
                    .environment(\.liveBandOverBar, barInBand)
                    .frame(maxWidth: barInBand ? bandBarWidth : nil)
                    .keepsOffFold()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if barInBand && !browser.isBarCollapsed {
                BottomBar(docked: true)
                    .frame(maxWidth: bandBarWidth)
                    .keepsOffFold()
                    .opacity(browser.splitList != nil || browser.launcherShown || browser.panel == .tabs || browser.pageBecomingSummary || browser.hidingItems != nil ? 0 : 1)
                    .allowsHitTesting(browser.hidingItems == nil && browser.splitList == nil)
                    .animation(.easeOut(duration: 0.2), value: browser.pageBecomingSummary)
                    .animation(.launcher, value: browser.launcherShown)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, max(bottomInset - 20, 9) + (barInBand && browser.isBarCollapsed && !browser.bandShowsStrip ? 8 : 0))
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom))
    }


    /// Offers and toasts sit just above the band, not where the floating bar was.
    private var playerLift: CGFloat {
        let live = showsPlayer ? LiveBand.height(minimized: browser.bandShowsStrip) : 0
        guard barInBand else { return live }
        // 12 above the band, or 12 above the safe area with no band.
        return max(live + (browser.isBarCollapsed ? 0 : Theme.barHeight + 5) - Theme.barHeight - 28, -Theme.barHeight - 8)
    }

    private var splitHalves: (top: BrowserTab, bottom: BrowserTab?)? {
        if let split = browser.split, let top = browser.tab(split.top), let bottom = browser.tab(split.bottom) {
            return (top, bottom)
        }
        return browser.splitPickingTop.map { ($0, nil) }
    }

    /// The tab on screen, or the two halves of a split. On an open Duo the bar is
    /// narrower than the page, which runs on under it: told where the bar starts,
    /// it would stop there, leaving a blank band across the screen either side.
    @ViewBuilder
    private var pages: some View {
        // Picking the second page and showing it are one view, for the same reason.
        if let halves = splitHalves {
            SplitPages(top: halves.top, bottom: halves.bottom, barTop: barInBand ? coveredFrom : uprightFold != nil ? .greatestFiniteMagnitude : barTop, onBand: barInBand)
        } else if let tab = browser.selectedTab {
            PagePane(tab: tab, barTop: barInBand ? coveredFrom : standsOnFold || uprightFold != nil ? .greatestFiniteMagnitude : barTop)
        }
    }

    /// Text that reads on whatever is behind the status bar.
    private var statusBarStyle: UIStatusBarStyle {
        // The summary and Browse for Me sit on the app's own canvas.
        if browser.showsOnboarding { return .lightContent }  // the welcome is always dark
        if browser.cook != nil || uprightFold != nil && browser.reader != nil { return .default }  // the paper follows the theme
        if splitBesideClock { return .lightContent }  // on the black beside the halves
        if bandWrapsClock && browser.reader == nil && browser.cook == nil && browser.panel == .none { return .lightContent }  // on the band
        if browser.summary != nil || browser.browseForMe != nil || browser.panel == .todos || browser.panel == .today
            || browser.panel == .shopping || browser.panel == .readLater || browser.panel == .feed || browser.digest != nil {
            return .default
        }
        if browser.panel == .tabs { return .lightContent }  // the switcher is always dark
        guard let color = browser.topTab?.topColor else { return .default }
        return color.isLight ? .darkContent : .lightContent
    }

    private func panelBinding(_ panel: BrowserModel.Panel) -> Binding<Bool> {
        Binding(
            get: { browser.panel == panel },
            set: { if !$0, browser.panel == panel { browser.panel = .none } })
    }
}

/// A page that didn't load: roko's eclipse, large, its inner disc slowly
/// crossing while the page is down; what went wrong in a sentence, about the
/// site by name; and the one thing that helps. Offline, it waits for the
/// connection and loads the page by itself.
private struct LoadErrorView: View {
    let error: LoadError
    let canGoBack: Bool
    /// Away from a page that won't be shown: back, or with nothing to go back to, out of the tab.
    let leave: () -> Void
    let retry: () -> Void
    let search: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BrowserModel.self) private var browser
    /// One monitor for the app, not one per redraw of this view.
    private var online: Connection { .shared }
    /// The connection came back while this showed: say so, and load.
    @State private var cameBack = false

    private var site: String { error.host ?? "This site" }

    private var headline: String {
        switch error.kind {
        case .offline: "You're offline"
        case .notFound: "\(site) doesn't exist"
        case .notAnswering: "\(site) isn't answering"
        case .slow: "\(site) is taking too long"
        case .unsafe: "\(site) isn't safe to open"
        case .crashed: "This page keeps stopping"
        case .other: "\(site) didn't load"
        }
    }

    private var line: String {
        switch error.kind {
        case .offline: cameBack ? "Back online. Loading it again." : "It loads by itself once you're back online."
        case .notFound: "Check the address, or search for it."
        case .notAnswering: "It may be down for a moment."
        case .slow: "Its server is slow right now."
        case .unsafe: "Its certificate doesn't match. Someone could be reading what you send."
        case .crashed: "It used more than this iPhone could give it."
        case .other: error.detail
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // A 9-second drift needs few frames; none while covered or away.
            TimelineView(.animation(minimumInterval: 1 / 12,
                                    paused: reduceMotion || browser.panel != .none || scenePhase != .active)) { context in
                // The inner disc drifts across and back, once every 9 seconds.
                let phase = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 9) + 1) / 2
                Eclipse(shift: phase)
                    .fill(Theme.ink, style: FillStyle(eoFill: true))
                    .frame(width: 132, height: 132)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 44)

            VStack(alignment: .leading, spacing: 10) {
                Text(headline)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(line)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                HStack(spacing: 28) {
                    if error.kind == .notFound, let host = error.host {
                        Button("Search instead") { search(host) }
                            .foregroundStyle(Theme.accentText)
                    }
                    if error.kind == .unsafe {
                        Button(canGoBack ? "Go back" : "Close this tab", action: leave)
                            .foregroundStyle(Theme.accentText)
                    } else {
                        Button(error.kind == .offline ? "Try now" : "Try again", action: retry)
                            .foregroundStyle(error.kind == .notFound ? Theme.secondaryInk : Theme.accentText)
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(minHeight: 44)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            Spacer()
            // Sits a little low, nearer the thumb and the bar.
            Spacer().frame(height: Theme.barHeight + 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .animation(.easeOut(duration: 0.25), value: cameBack)
        .onChange(of: online.isUp) { was, up in
            // Only a real return, from down to up: a dropped connection that
            // never left the network (most Wi-Fi blips) has nothing to wait for.
            if was == false, up == true, error.kind == .offline {
                cameBack = true
                retry()
            }
        }
        .task {
            // Already up when the error came (a blip): no point waiting.
            if error.kind == .offline, online.isUp == true { cameBack = true; retry() }
        }
    }
}

/// roko's eclipse with its inner disc moved along: 0 left of where the app
/// icon has it, 1 right of it, so the mark seems to pass through an eclipse.
nonisolated struct Eclipse: Shape {
    var shift: Double
    var animatableData: Double {
        get { shift }
        set { shift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let unit = side / 600
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        path.addEllipse(in: CGRect(x: origin.x, y: origin.y, width: side, height: side))
        // The app icon's cut-out sits at x 244; it travels 60...270, inside
        // the disc (past 300 it would poke out of the edge as a sliver).
        let x = 60 + 210 * shift
        path.addEllipse(in: CGRect(x: origin.x + x * unit, y: origin.y + 150 * unit, width: 300 * unit, height: 300 * unit))
        return path
    }
}

/// Whether the iPhone has a connection, as it changes.
@Observable
private final class Connection {
    static let shared = Connection()
    /// Nil until the first reading.
    private(set) var isUp: Bool?
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.isUp = up }
        }
        monitor.start(queue: DispatchQueue(label: "roko.connection"))
    }

    deinit { monitor.cancel() }
}

/// A panel that rises from the bottom edge and sits flush with it: rounded
/// top corners, square bottom ones, running under the home indicator. Tap
/// outside or drag it down to close.
private struct BottomPanel<Content: View>: View {
    @Environment(BrowserModel.self) private var browser
    let dismiss: () -> Void
    @ViewBuilder let content: Content
    @State private var shown = false
    @State private var drag: CGFloat = 0
    /// The screen it rises on: turned sideways it's short and wide, so the
    /// panel keeps below the top and to a column's width.
    @State private var room: CGSize = .zero
    /// Propped open it stays on the lower half, under the fold.
    @Environment(\.fold) private var fold
    @Environment(\.propped) private var propped
    @State private var roomBottom: CGFloat = 0

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
                        .frame(maxHeight: room.height > 0 ? min(640, room.height - 24, belowFold) : 640)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: room.width > room.height ? 560 : .infinity)
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                        .fill(Theme.panel)
                        .ignoresSafeArea(edges: .bottom)
                }
                // Above the bar on a Duo bent open. Lying flat, in the middle.
                .staysWithBar(browser)
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { roomBottom = $0 }
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.12)) { shown = true } }
    }

    /// The content's room under the fold, its grab handle and a little air taken off.
    private var belowFold: CGFloat {
        guard propped, let fold else { return .greatestFiniteMagnitude }
        return max(roomBottom - fold.maxY - 21, 200)
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

/// Reader Mode: a sheet, or a book across the fold of an open Duo. Kept apart
/// so the browser's body stays small enough for the compiler.
private struct ReaderScreens: ViewModifier {
    @Bindable var browser: BrowserModel
    let asBook: Bool
    /// Read as the sheet goes away: the book taking over isn't the reader closing.
    @State private var bookTookOver = false
    /// A story from the feed stays in its sheet, for its switch to the summary and the page.
    private var showsBook: Bool { asBook && browser.reader?.story == nil }

    func body(content: Content) -> some View {
        content
            .onChange(of: asBook, initial: true) { bookTookOver = asBook }
            .sheet(item: Binding(get: { showsBook ? nil : browser.reader }, set: { if !bookTookOver { browser.reader = $0 } })) { model in
                ReaderView(model: model)
            }
            .overlay {
                if showsBook, let model = browser.reader {
                    BookView(model: model)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: browser.reader?.id)
    }
}

/// Cook Mode, under the toasts that report on its timers.
private struct CookScreen: ViewModifier {
    let browser: BrowserModel

    func body(content: Content) -> some View {
        content
            .overlay {
                if let cook = browser.cook {
                    CookView(model: cook)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: browser.cook?.id)
    }
}

/// Read Later and its Summarize all, over the page: kept apart so the
/// browser's body stays small enough for the compiler.
private struct ReadLaterScreens: ViewModifier {
    let browser: BrowserModel
    let besideFold: CGRect?

    func body(content: Content) -> some View {
        content
            .overlay {
                if browser.readLaterBeside || browser.panel == .readLater || browser.panel == .command && browser.launcherReturn == .readLater {
                    ReadLaterView()
                        .besideFold(besideFold, hidden: browser.panel == .tabs)
                        .transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if browser.panel == .feed || browser.panel == .command && browser.launcherReturn == .feed {
                    FeedView()
                        .transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if let digest = browser.digest {
                    // Over the list it was asked from, rising from its bar.
                    DigestView(model: digest)
                        .besideFold(besideFold, hidden: browser.panel == .tabs)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.spring(duration: 0.42, bounce: 0.06), value: browser.digest?.id)
            .animation(.spring(duration: 0.42, bounce: 0.06), value: browser.readLaterBeside)
    }
}

private extension View {
    /// One of roko's screens, on the leading side of an open Duo's fold with the
    /// page across it. Out of the way while the tab switcher is up.
    func besideFold(_ fold: CGRect?, hidden: Bool) -> some View {
        frame(width: fold?.minX)
            // Not clipped to its frame: it runs on under the home indicator.
            .mask { RoundedRectangle(cornerRadius: fold != nil ? 16 : 0).ignoresSafeArea() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
    }
}

/// In place of the bar while Hide Distracting Items is on.
private struct HideItemsBar: View {
    @Environment(BrowserModel.self) private var browser
    let hidden: Int

    var body: some View {
        HStack(spacing: 6) {
            Button { browser.undoHiddenItem() } label: {
                Glyph(.back)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(hidden == 0)
            .opacity(hidden == 0 ? 0.35 : 1)
            .accessibilityLabel("Undo")

            VStack(spacing: 1) {
                Text(hidden == 0 ? "Tap something to hide" : hidden == 1 ? "1 thing hidden" : "\(hidden) things hidden")
                    .font(.system(size: 15, weight: .medium))
                    .contentTransition(.numericText())
                Text("Tap it again to hide it")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .frame(maxWidth: .infinity)
            .lineLimit(1)

            Button("Done") { browser.finishHidingItems() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(minWidth: 56, minHeight: 44)
                .contentShape(.rect)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.barHeight + 8)
        .barSurface(cornerRadius: Theme.barRadius)
        .compositingGroup()
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.2), value: hidden)
        .sensoryFeedback(.impact(weight: .light), trigger: hidden)
    }
}

/// Over the page: a file that just finished, and the mini player. Kept apart so the browser's body stays small enough for
/// the compiler.
private struct PageExtras: ViewModifier {
    let browser: BrowserModel
    let showsPlayer: Bool
    let playerLift: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                // A file that just finished: built like the other offers.
                if let item = Downloads.shared.finished, browser.panel == .none, browser.cookieOffer == nil,
                   !browser.copiedLinkOffer, browser.appOffer == nil {
                    HStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Glyph(.download, size: 18)
                            Text(item.name)
                                .font(.system(size: 15, weight: .medium))
                                .truncationMode(.middle)
                        }
                        Button("Open") { Downloads.shared.open(item) }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .padding(.trailing, 16)
                    .barSurface(cornerRadius: 14)
                    .compositingGroup()
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, Theme.barHeight + 20 + playerLift)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                }
            }
            .animation(.snappy(duration: 0.3), value: Downloads.shared.finished?.id)
    }
}

/// One tab's page, as it fills the screen or one half of a split: the web
/// view, the snapshot standing in until it's live, why it didn't load, and the
/// lock over a private tab.
private struct PagePane: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.scenePhase) private var scenePhase
    let tab: BrowserTab
    let barTop: CGFloat

    var body: some View {
        ZStack {
            WebViewHost(
                tab: tab,
                barTop: barTop,
                onSummarize: { browser.summarize(from: $0) },
                onPreview: { showing in
                    if browser.pageBecomingSummary != showing { browser.pageBecomingSummary = showing }
                },
                onScrollDirection: { down in
                    if browser.isBarCollapsed != down { browser.isBarCollapsed = down }
                },
                onPinchTabs: { browser.showTabs(fresh: false) },
                onBackToSaved: { browser.returnToSaved(from: tab) },
                onTouch: { webView in
                    guard let touched = browser.tabs.first(where: { $0.webView === webView }),
                          browser.split?.contains(touched.id) == true, browser.selectedID != touched.id else { return }
                    browser.select(touched)
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
                LoadErrorView(error: error,
                              canGoBack: tab.webView?.canGoBack == true,
                              leave: {
                                  if let webView = tab.webView, webView.canGoBack { webView.goBack() } else { browser.close(tab) }
                              },
                              retry: { if let url = tab.url { tab.load(url) } },
                              search: { browser.open(SearchEngine.current.searchURL(for: $0), inNewTab: false) })
            }

            // Locked behind Face ID, and hidden in the app switcher too.
            if tab.isPrivate, PrivacyLock.shared.hides(tab.id) || (PrivacyLock.shared.isEnabled && scenePhase == .background) {
                LockCover()
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}

/// Split View: two tabs, one above the other, as two rounded cards on a dark
/// band (after Amie). Drag the band to anywhere you like; it stays where you
/// let go. Dragged nearly shut, that half closes and the other has the screen
/// again. The bar works the half you last touched; the other is dimmed a little.
private struct SplitPages: View {
    @Environment(BrowserModel.self) private var browser
    let top: BrowserTab
    /// Nil while the bottom half is still to be chosen.
    let bottom: BrowserTab?
    let barTop: CGFloat
    /// The bar lies in the band: the halves part on its ground, one surface with it.
    var onBand = false
    @Environment(\.fold) private var fold
    @State private var drag: CGFloat = 0

    private let band: CGFloat = 28
    private let corner: CGFloat = 26
    /// Side by side the cards are smaller, and so is their rounding.
    private let sideCorner: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            // Turned sideways, the halves sit side by side: the first on the left.
            let sideBySide = proxy.size.width > proxy.size.height
            let length = sideBySide ? proxy.size.width : proxy.size.height + proxy.safeAreaInsets.bottom
            // On an open Duo the halves part at the fold until you drag them elsewhere.
            let atFold = browser.splitFraction == 0.5 ? foldMiddle(in: proxy, sideBySide: sideBySide) : nil
            let first = min(max((atFold.map { $0 - band / 2 } ?? length * browser.splitFraction) + drag, 0), length - band)
            Group {
                if sideBySide {
                    HStack(spacing: 0) {
                        // Side by side, two whole cards between the black strips.
                        card(top, shape: RoundedRectangle(cornerRadius: sideCorner))
                            .frame(width: first)
                        SplitHandle(drag: $drag, total: length, band: band, sideways: true, top: top, bottom: bottom)
                            .frame(width: band)
                        second(RoundedRectangle(cornerRadius: sideCorner), from: .trailing)
                    }
                } else {
                    VStack(spacing: 0) {
                        card(top, shape: UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner))
                            .frame(height: first)
                        SplitHandle(drag: $drag, total: length, band: band, top: top, bottom: bottom)
                            .frame(height: band)
                        second(UnevenRoundedRectangle(topLeadingRadius: corner, topTrailingRadius: corner), from: .bottom)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height + (sideBySide ? 0 : proxy.safeAreaInsets.bottom), alignment: .top)
            .animation(.snappy(duration: 0.2), value: browser.selectedID)
            .animation(.snappy(duration: 0.3), value: browser.splitList)
        }
        // The list covers the second half, so the bar works the page beside it.
        .onChange(of: browser.splitList) { _, list in
            if list != nil, browser.selectedID != top.id { browser.select(top) }
        }
        // Between and under the cards, not behind the status bar: that band keeps
        // the top page's colour, so the clock stays readable.
        .background {
            if onBand {
                BandGround(color: browser.selectedTab?.topColor).ignoresSafeArea(edges: .bottom)
            } else {
                Color.black.ignoresSafeArea(edges: .bottom)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// Where the fold runs across this view, if it lies along the way the halves part.
    private func foldMiddle(in proxy: GeometryProxy, sideBySide: Bool) -> CGFloat? {
        guard let fold, (fold.height > fold.width) == sideBySide else { return nil }
        let frame = proxy.frame(in: .global)
        let middle = sideBySide ? fold.midX - frame.minX : fold.midY - frame.minY
        return middle > 0 && middle < (sideBySide ? frame.width : frame.height) ? middle : nil
    }

    /// The second half: to-dos or the shopping list when they're open, its
    /// page, or the card that asks for one.
    @ViewBuilder
    private func second(_ shape: some Shape, from edge: Edge) -> some View {
        Group {
            if let list = browser.splitList {
                Group {
                    if list == .todos { TodoView() } else { ShoppingView() }
                }
                .clipShape(shape)
                .transition(.move(edge: edge).combined(with: .opacity))
            } else if let bottom {
                card(bottom, shape: shape)
            } else {
                SplitPicker(top: top, beside: edge == .trailing)
                    .clipShape(shape)
                    .transition(.move(edge: edge).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ tab: BrowserTab, shape: some Shape) -> some View {
        PagePane(tab: tab, barTop: barTop)
            .overlay {
                if browser.selectedID != tab.id { Color.black.opacity(0.12).allowsHitTesting(false) }
            }
            .clipShape(shape)
    }
}

/// The band between the halves: swap at one end, the grip in the middle,
/// close at the other, and the whole band drags. Upright between stacked
/// halves when the iPhone is turned sideways.
private struct SplitHandle: View {
    @Environment(BrowserModel.self) private var browser
    @Binding var drag: CGFloat
    let total: CGFloat
    let band: CGFloat
    var sideways = false
    let top: BrowserTab
    let bottom: BrowserTab?
    @State private var settled = 0

    private var close: some View {
        Button { browser.endSplit() } label: {
            Glyph(.close, size: 16)
                .frame(width: sideways ? band : 52, height: sideways ? 44 : band)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel("Close Split View")
    }

    var body: some View {
        // Nothing to swap with a half still to choose, or a list in it.
        let canSwap = bottom != nil && browser.splitList == nil
        let layout = sideways ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            // Upright it leaves its place, so close takes the top; lying down an
            // empty place keeps the grip in the middle.
            if canSwap || !sideways {
                Button { browser.swapSplit() } label: {
                    Glyph(.swap, size: 17)
                        .rotationEffect(.degrees(sideways ? 90 : 0))
                        .frame(width: sideways ? band : 52, height: sideways ? 52 : band)
                        .contentShape(.rect)
                }
                .buttonStyle(GlyphButtonStyle())
                .accessibilityLabel("Swap the halves")
                .opacity(canSwap ? 1 : 0)
                .disabled(!canSwap)
            }
            // Upright, close goes under swap at the top: at the bottom the bar would cover it.
            if sideways { close }
            Spacer()
            Capsule()
                .fill(.white.opacity(0.42))
                .frame(width: sideways ? 5 : 46, height: sideways ? 46 : 5)
            Spacer()
            if !sideways { close }
        }
        .padding(sideways ? .vertical : .horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white.opacity(0.85))
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag = sideways ? $0.translation.width : $0.translation.height }
            .onEnded { value in
                let moved = sideways ? value.translation.width : value.translation.height
                let thrownBy = sideways ? value.predictedEndTranslation.width : value.predictedEndTranslation.height
                let here = browser.splitFraction + moved / total
                let thrown = browser.splitFraction + thrownBy / total
                withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
                    drag = 0
                    if here < 0.12 || thrown < 0.04 {
                        browser.endSplit(keeping: bottom)
                    } else if here > 0.88 || thrown > 0.96 {
                        browser.endSplit(keeping: top)
                    } else {
                        // Where you let go, kept clear of the edges so both halves stay usable.
                        browser.splitFraction = min(max(here, 0.18), 0.82)
                    }
                }
                settled += 1
            })
        .sensoryFeedback(.impact(weight: .light), trigger: settled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View handle")
    }
}

/// Split View's bottom half before it has a page: what goes here, as a
/// search field that opens the bar, and your other open tabs to tap.
private struct SplitPicker: View {
    @Environment(BrowserModel.self) private var browser
    let top: BrowserTab
    /// Side by side (the iPhone turned): it opens beside, not below.
    var beside = false

    private var others: [BrowserTab] {
        browser.tabs
            .filter { $0.id != top.id && $0.isPrivate == top.isPrivate && $0.url != nil }
            .sorted { $0.lastActive > $1.lastActive }
    }

    private func listButton(_ list: BrowserModel.Panel, glyph: Glyph.Kind, title: String) -> some View {
        Button { browser.panel = list } label: {
            HStack(spacing: 10) {
                Glyph(glyph, size: 19).foregroundStyle(Theme.secondaryInk)
                Text(title)
                    .font(.system(size: 16))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.raised, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.edge))
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(beside ? "Open beside" : "Open below")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.top, 22)

                Button { browser.pickSplitPage() } label: {
                    HStack(spacing: 12) {
                        Glyph(.search, size: 19).foregroundStyle(Theme.secondaryInk)
                        Text(top.isPrivate ? "Private search or address" : "Search or enter address")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(Theme.raised, in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.edge))
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())

                // Not a page: the list itself, beside the one on top.
                HStack(spacing: 10) {
                    listButton(.todos, glyph: .todo, title: "To-dos")
                    listButton(.shopping, glyph: .basket, title: "Shopping")
                }

                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open tabs")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.bottom, 6)
                        ForEach(others.prefix(8)) { tab in
                            Button { browser.startSplit(with: tab) } label: {
                                HStack(spacing: 12) {
                                    SiteIcon(host: tab.url?.displayHost ?? "", size: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tab.displayTitle).font(.system(size: 16))
                                        Text(tab.url?.displayHost ?? "")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                    .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 9)
                                .contentShape(.rect)
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            // Clear of the floating bar.
            .padding(.bottom, Theme.barHeight + 40)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

/// The first time roko opens, over everything. Kept apart so the browser's
/// body stays small enough for the compiler.
private struct WelcomeCover: ViewModifier {
    let browser: BrowserModel

    func body(content: Content) -> some View {
        content
            .overlay {
                if browser.showsOnboarding {
                    Onboarding()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.35), value: browser.showsOnboarding)
    }
}
