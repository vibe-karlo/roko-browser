import SwiftData
import SwiftUI

/// The tab switcher, after Arc: your tabs as big overlapping page cards that
/// scroll sideways, the focused one's name and close above it. Tap a card to open it,
/// throw it up to close it. The bottom row is the page's bar, its three places where they
/// were: private, +, and a menu. Pull it up to go back to your page.
/// On an open iPhone Duo there's room for more: a grid of wide cards, each page's top whole.
struct TabStackView: View {
    @Environment(BrowserModel.self) private var browser
    @Query private var todos: [Todo]
    /// The card centred in the carousel; follows scrolling.
    @State private var focused: BrowserTab.ID?
    /// How far the whole switcher has been pulled up (negative), following the finger.
    @State private var lift: CGFloat = 0
    /// A second swipe up straight after the one that opened the switcher isn't a throw.
    @State private var throwsFrom = Date.now.addingTimeInterval(0.5)
    /// A tab was thrown away while the switcher is open: offer it back.
    @State private var closedHere = false
    /// Where the + is on screen, for the launcher to grow out of.
    @State private var plusFrame: CGRect = .zero
    /// The tab roko's screens' cards sit after: the one you were on as the switcher opened,
    /// so the screen you just left is a swipe away. Held while it's open, so nothing moves.
    @State private var anchor: BrowserTab.ID?

    /// A card in the carousel: a tab, or one of roko's screens.
    private enum Entry: Identifiable {
        case tab(BrowserTab)
        case screen(RecentScreen)
        var id: UUID {
            switch self {
            case .tab(let tab): tab.id
            case .screen(let screen): screen.id
            }
        }
    }

    /// Hidden with private browsing locked, as history is.
    private var screens: [RecentScreen] { PrivacyLock.shared.isLocked ? [] : RecentScreens.shared.items }

    private var entries: [Entry] {
        var list = browser.tabs.map(Entry.tab)
        let cards = screens.map(Entry.screen)
        guard !cards.isEmpty else { return list }
        let at = anchor.flatMap { id in list.firstIndex { $0.id == id } }.map { $0 + 1 } ?? list.count
        list.insert(contentsOf: cards, at: at)
        return list
    }

    private let returnThreshold: CGFloat = 90

    var body: some View {
        GeometryReader { proxy in
            // Turned sideways the cards stay upright and narrow: several at
            // once to swipe through, rather than one wide strip of a page.
            let sideways = proxy.size.width > proxy.size.height
            let bottomInset = proxy.safeAreaInsets.bottom
            let height = proxy.size.height + bottomInset
            let cardHeight = sideways ? height - 124 : min((proxy.size.width * 0.76).rounded() * 1.95, height - 230)
            let cardWidth = sideways ? (cardHeight * 0.62).rounded() : (proxy.size.width * 0.76).rounded()
            // Each card shows this much before the next one covers it.
            // Most of the focused card shows; the next one just overlaps its edge.
            // Sideways there's room for each card whole, side by side.
            let stride = sideways ? cardWidth + 14 : (cardWidth * 0.87).rounded()
            // No other iPhone is this roomy both ways.
            let isGrid = min(proxy.size.width, proxy.size.height) >= 600

            VStack(spacing: 0) {
                // Pins live above the address field, not here.
                Spacer(minLength: 0)

                if entries.isEmpty {
                    Text("No open tabs")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(height: cardHeight + 40)
                } else if isGrid {
                    grid(width: proxy.size.width, columns: sideways ? 3 : 2)
                } else {
                    carousel(cardWidth: cardWidth, stride: stride, cardHeight: cardHeight,
                             screenWidth: proxy.size.width, stacks: !sideways)
                }

                Spacer(minLength: 0)
                // Where you are, among more than the eye can count. Sideways they show for themselves.
                if !sideways && !isGrid && browser.tabs.count > 1 { position }
                reopenOffer
                bottomRow(wide: isGrid || sideways)
                    // Into the home indicator's strip, as the page's bar goes.
                    .padding(.bottom, max(bottomInset - 20, 9))
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background { backdrop }
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .dark)
        .offset(y: lift)
        .opacity(1 + lift / 600)
        // A thrown-away tab lands with a thud.
        .sensoryFeedback(.impact(weight: .medium), trigger: browser.tabs.count) { old, new in new < old }
        .onAppear {
            anchor = browser.selectedID ?? browser.tabs.last?.id
            focused = browser.screenForSwitcher ?? browser.selectedID ?? entries.last?.id
            browser.screenForSwitcher = nil
            closedHere = false
            throwsFrom = Date.now.addingTimeInterval(0.5)
        }
        // Close All can be taken back only from here, straight after it.
        .onDisappear { browser.closedGroup = nil }
        .animation(.snappy(duration: 0.3), value: closedHere)
        .animation(.snappy(duration: 0.3), value: browser.closedGroup == nil)
        .animation(.snappy(duration: 0.3), value: browser.recentlyClosed.count)
    }

    // MARK: Grid

    private func grid(width: CGFloat, columns: Int) -> some View {
        let margin: CGFloat = 16, gap: CGFloat = 18
        let cardWidth = ((width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let cardHeight = (cardWidth * 0.64).rounded()
        return ScrollViewReader { reader in
            ScrollView {
                // Lazily: with every tile made at once, every tab's picture was read at
                // once, and most were thrown away again before they could be shown.
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gap), count: columns), spacing: 16) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .tab(let tab):
                            TabTile(tab: tab, width: cardWidth, height: cardHeight,
                                    isCurrent: tab.id == browser.selectedID,
                                    open: { open(tab) },
                                    close: { close(tab) },
                                    closeAll: closeAllAction,
                                    split: splitAction(with: tab))
                            .id(tab.id)
                        case .screen(let screen):
                            ScreenTile(screen: screen, width: cardWidth, height: cardHeight,
                                       open: { open(screen) }, close: { close(screen) })
                            .id(screen.id)
                        }
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            // Cards leaving at either end fade rather than being sliced off.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            .onAppear {
                // A screen of tiles is more than the dozen pictures a carousel needs.
                BrowserTab.keepPictures(30)
                reader.scrollTo(browser.selectedID, anchor: .center)
            }
            .onDisappear { BrowserTab.keepPictures(BrowserTab.usualPictures) }
            .animation(.snappy(duration: 0.3), value: entries.map(\.id))
        }
    }

    // MARK: Cards

    private func carousel(cardWidth: CGFloat, stride: CGFloat, cardHeight: CGFloat,
                          screenWidth: CGFloat, stacks: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: stride - cardWidth) {
                let all = entries
                let focusedIndex = all.firstIndex { $0.id == focused } ?? 0
                ForEach(Array(all.enumerated()), id: \.element.id) { index, entry in
                    Group {
                        switch entry {
                        case .tab(let tab):
                            TabCard(tab: tab, width: cardWidth, height: cardHeight,
                                    titleWidth: (stacks ? stride : cardWidth) - 8, isFocused: tab.id == focused,
                                    isBehind: stacks && index < focusedIndex, overlaps: stacks,
                                    showsNeighbourIcon: !stacks,
                                    throwsFrom: throwsFrom,
                                    open: { open(tab) },
                                    close: { close(tab) },
                                    closeAll: closeAllAction,
                                    split: splitAction(with: tab))
                        case .screen(let screen):
                            ScreenCard(screen: screen, width: cardWidth, height: cardHeight,
                                       titleWidth: (stacks ? stride : cardWidth) - 8, isFocused: screen.id == focused,
                                       isBehind: stacks && index < focusedIndex, overlaps: stacks,
                                       showsNeighbourIcon: !stacks, throwsFrom: throwsFrom,
                                       open: { open(screen) }, close: { close(screen) })
                        }
                    }
                    // As in Arc: tabs to the left sink back into a stack behind
                    // the focused card, smaller and tucked under it; the next tab
                    // on the right stays full size, laid over it. Drawn by the
                    // scroll view itself, so it costs nothing per frame in code.
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        let back = stacks ? max(0, -phase.value) : 0
                        return content
                            .scaleEffect(1 - 0.1 * back, anchor: .trailing)
                            .offset(x: back * stride * 0.55)
                            .brightness(-0.12 * back)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focused, anchor: .center)
        .contentMargins(.horizontal, (screenWidth - cardWidth) / 2, for: .scrollContent)
        .scrollClipDisabled()
        .frame(height: cardHeight + 40)
        .animation(.snappy(duration: 0.3), value: entries.map(\.id))
    }

    /// Nil with only one tab open and nothing else here.
    private var closeAllAction: (() -> Void)? {
        guard browser.tabs.count > 1 || !screens.isEmpty && !browser.tabs.isEmpty else { return nil }
        return { closeAllTabs() }
    }

    private func splitAction(with tab: BrowserTab) -> (() -> Void)? {
        guard canSplit(with: tab) else { return nil }
        return {
            browser.panel = .none
            browser.startSplit(with: tab)
        }
    }

    /// Split with the tab on screen: another tab of the same kind, not already beside it.
    private func canSplit(with tab: BrowserTab) -> Bool {
        guard let current = browser.selectedTab, current.id != tab.id, current.isPrivate == tab.isPrivate else { return false }
        return browser.split?.contains(tab.id) != true
    }

    private func open(_ tab: BrowserTab) {
        // A locked private tab opens once Face ID says so.
        if tab.isPrivate, PrivacyLock.shared.hides(tab.id) {
            Task {
                guard await PrivacyLock.shared.unlock("Show your private tab") else { return }
                browser.select(tab)
                browser.panel = .none
            }
            return
        }
        browser.select(tab)
        browser.panel = .none
    }

    /// Keep a neighbour centred so the carousel doesn't jump to the start.
    private func focusNeighbour(of id: UUID) {
        let all = entries
        guard focused == id, let index = all.firstIndex(where: { $0.id == id }) else { return }
        let neighbours = all.indices.filter { $0 != index }
        focused = neighbours.min { abs($0 - index) < abs($1 - index) }.map { all[$0].id }
    }

    private func open(_ screen: RecentScreen) {
        browser.panel = .none
        browser.openScreen(screen)
    }

    private func close(_ screen: RecentScreen) {
        focusNeighbour(of: screen.id)
        RecentScreens.shared.remove(screen.id)
    }

    private func close(_ tab: BrowserTab) {
        focusNeighbour(of: tab.id)
        browser.close(tab)
        browser.closedGroup = nil
        if !tab.isPrivate, tab.url != nil { closedHere = true }
    }

    /// The tab just thrown away, a tap from coming back with its history.
    /// Built like the copied-link offer: what it is, then one word to act.
    @ViewBuilder
    private var reopenOffer: some View {
        if let group = browser.closedGroup {
            offer(action: "Undo", perform: {
                browser.reopenClosedGroup()
                focused = browser.selectedID ?? browser.tabs.last?.id
            }) {
                Text(group.screens.isEmpty ? (group.tabs.count == 1 ? "1 tab closed" : "\(group.tabs.count) tabs closed")
                     : "\(group.tabs.count + group.screens.count) closed")
                    .font(.system(size: 15, weight: .medium))
            }
        } else if closedHere, let closed = browser.recentlyClosed.last {
            offer(action: "Reopen", perform: {
                browser.reopenClosedTab()
                closedHere = false
            }) {
                HStack(spacing: 10) {
                    SiteIcon(host: closed.url.displayHost, size: 18)
                    Text(closed.url.displayHost)
                        .font(.system(size: 15, weight: .medium))
                }
            }
        }
    }

    private func offer(action: String, perform: @escaping () -> Void,
                       @ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 14) {
            label()
            Button(action, action: perform)
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
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// The selected page, blurred far out of focus: the switcher takes on the
    /// colour of where you were, the way Arc's does.
    private var backdrop: some View {
        // Over the canvas, not beside it: the picture's own width mustn't size this.
        Theme.canvas
            .overlay {
                if let picture = browser.selectedTab?.thumbnail {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 60, opaque: true)
                        // Low enough that a white page tints the dark rather than greying it.
                        .opacity(0.14)
                }
            }
            .task(id: browser.selectedID) { await browser.selectedTab?.loadThumbnail() }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: Bottom row

    /// "3 of 12", under the cards. Digits that hold their place as you swipe.
    private var position: some View {
        // Counting tabs: on a screen's card it steps aside, keeping its room.
        let index = browser.tabs.firstIndex { $0.id == focused }
        return Text("\((index ?? 0) + 1) of \(browser.tabs.count)")
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryInk)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: index)
            .opacity(index == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: index == nil)
            .padding(.bottom, 2)
    }

    /// The page's bar: the same three places at the same distances, so the + doesn't
    /// move as you come here, on no surface of its own. What isn't about tabs is in the menu.
    private func bottomRow(wide: Bool) -> some View {
        HStack(spacing: 0) {
            Button { browser.showCommandBar(mode: .privateTab, over: .tabs) } label: {
                Glyph(.eyeClosed, size: 22)
                    .padding(.leading, BottomBar.dockedInset)
                    .frame(width: 72, height: Theme.barHeight, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("New private tab")
            Spacer(minLength: 8)
            Button {
                browser.launcherOrigin = plusFrame
                // Over the switcher, which stays: cancelling comes back here, with Reopen still on offer.
                browser.showCommandBar(over: .tabs)
            } label: {
                Glyph(.plus, size: 22, weight: 2)
                    .frame(width: 104, height: 38)
                    .background(.white.opacity(0.14), in: .capsule)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { plusFrame = $0 }
                    .frame(height: Theme.barHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("New tab")
            Spacer(minLength: 8)
            Menu {
                Button { browser.panel = .today } label: { Label("Today", image: "phosphor/today") }
                Button { browser.panel = .feed } label: { Label("News", image: "phosphor/news") }
                Button { browser.panel = .readLater } label: { Label("Saved", image: "phosphor/readLater") }
                Button { browser.panel = .todos } label: { Label(todosLabel, image: "phosphor/todo") }
                Button { browser.panel = .settings } label: { Label("Settings", image: "phosphor/settings") }
                if browser.tabs.count > 1 || !screens.isEmpty && !browser.tabs.isEmpty {
                    Divider()
                    Button(role: .destructive) { closeAllTabs() } label: {
                        Label("Close All Tabs", image: "phosphor/close")
                    }
                }
            } label: {
                Glyph(.chevronUp, size: 20, weight: 2)
                    // The glyph's ink is 11 inside its 38-point circle on the page's bar.
                    .frame(width: 38, height: 38)
                    .padding(.trailing, BottomBar.dockedInset - 11)
                    .frame(width: 72, height: Theme.barHeight, alignment: .trailing)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            // Its icons in the ink of the words beside them, not roko's orange.
            .tint(Theme.ink)
            .accessibilityLabel("More")
        }
        .padding(.top, 16)
        // Sideways and on the wide grid, together in the middle of the screen, as the bar
        // is. On a bent Duo, on one half: in the middle the + sat right on the bend.
        .frame(maxWidth: wide ? 480 : nil)
        .keepsOffFold()
        .contentShape(.rect)
        .highPriorityGesture(pullUp)
        // Open, a Duo's page bar is centred on the screen, whichever side the clock is. Shut,
        // on what the camera leaves, as the card is. The + stays where it was on the page.
        .ignoresSafeArea(.container, edges: browser.uprightFoldOpen ? .horizontal : [])
    }

    /// To-do, with how many are left today while any are.
    private var todosLabel: String {
        let left = todos.filter(\.isDueNow).count
        return left > 0 ? "To-do, \(left) left" : "To-do"
    }

    private func closeAllTabs() {
        browser.closeAllTabs()
        focused = browser.selectedID ?? entries.last?.id
    }

    private var pullUp: some Gesture {
        // Measured on screen: the row rides along with the switcher, so a local
        // measurement would shrink as it moves and the switcher would lag the finger.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dy = min(0, value.translation.height)
                // With nowhere to go back to, resist the pull instead of following it.
                lift = browser.selectedTab == nil ? dy / 6 : dy
            }
            .onEnded { value in
                let flung = value.predictedEndTranslation.height < -260
                if let tab = browser.selectedTab, lift < -returnThreshold || flung {
                    open(tab)
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { lift = 0 }
                }
            }
    }
}

/// One tab: its site and, when focused, its title above a card of the page.
/// Throw the card upward to close the tab.
private struct TabCard: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat
    let titleWidth: CGFloat
    let isFocused: Bool
    /// Left of the focused card, in the stack behind it.
    var isBehind = false
    /// Laid over its neighbour, rather than beside it.
    var overlaps = true
    /// Side by side, each card keeps its icon; laid over each other, only the focused one has a header.
    var showsNeighbourIcon = false
    var throwsFrom = Date.distantPast
    let open: () -> Void
    let close: () -> Void
    /// Nil with only one tab open.
    var closeAll: (() -> Void)? = nil
    /// With the tab on screen, split; nil for the tab on screen itself.
    var split: (() -> Void)? = nil

    @State private var throwOffset: CGFloat = 0
    private let closeDistance: CGFloat = 140
    private var corner: CGFloat { min(34, width * 0.16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            card
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isHidden ? "Private tab, locked" : tab.displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Close tab", close)
        .accessibilityAction(named: "Close all tabs") { closeAll?() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isFocused || showsNeighbourIcon {
                SiteIcon(host: isHidden ? "" : tab.url?.displayHost ?? "", size: 20)
            }
            if isFocused, tab.isPrivate {
                Glyph(.eyeClosed, size: 15).foregroundStyle(Theme.secondaryInk)
            }
            if isFocused, !isHidden {
                Text(tab.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if isFocused {
                Button(action: close) {
                    Glyph(.close, size: 14, weight: 2)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(GlyphButtonStyle())
                // Its ink on the line of the part of the card you can see.
                .padding(.trailing, -15)
                .accessibilityLabel("Close tab")
                .transition(.opacity)
            }
        }
        // Over the part of its card you can see, from the card's own edge.
        .frame(width: titleWidth, height: 28, alignment: .leading)
        .padding(.leading, 4)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .opacity(isBehind ? 0 : 1 + throwOffset / 200)
        .animation(.easeOut(duration: 0.18), value: isBehind)
    }

    private var card: some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay(alignment: .top) { preview }
            .clipShape(.rect(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.08)))
            // Cast leftward onto the card it overlaps, from one light on the right.
            .shadow(color: .black.opacity(overlaps ? 0.35 : 0), radius: 8, x: -5, y: 0)
            .contentShape(.rect(cornerRadius: corner))
            .onTapGesture(perform: open)
            .contextMenu {
                if let split, !isHidden {
                    Button(action: split) { Label("Open in Split View", image: "phosphor/split") }
                }
                Button(role: .destructive, action: close) { Label("Close Tab", image: "phosphor/close") }
                if let closeAll {
                    Button(role: .destructive, action: closeAll) { Label("Close All Tabs", image: "phosphor/close") }
                }
            }
            .offset(y: throwOffset)
            .opacity(1 + throwOffset / 700)
            // Far enough that letting go closes it.
            .sensoryFeedback(.impact(weight: .light), trigger: throwOffset < -closeDistance) { _, past in past }
            .gesture(UpwardPan(
                notBefore: throwsFrom,
                changed: { throwOffset = min(0, $0) },
                ended: { translation, velocity in
                    if -translation > closeDistance || velocity < -900 {
                        withAnimation(.easeIn(duration: 0.18)) { throwOffset = -1000 } completion: { close() }
                    } else {
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { throwOffset = 0 }
                    }
                }))
    }

    /// A private tab while it's locked: no picture, no name, no site.
    private var isHidden: Bool { tab.isPrivate && PrivacyLock.shared.hides(tab.id) }

    private var preview: some View { TabPicture(tab: tab, width: width, height: height) }
}

/// A tab's picture: the page as it last looked, or what stands in for it.
private struct TabPicture: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if tab.isPrivate && PrivacyLock.shared.hides(tab.id) {
                Theme.raised.overlay {
                    Glyph(.lock, size: 40).foregroundStyle(Theme.secondaryInk)
                }
            } else if let picture = tab.thumbnail {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    // From the left: a sideways picture in a narrow card keeps the
                    // site's logo, where the middle of the page wouldn't.
                    .frame(width: width, height: height, alignment: .topLeading)
                    .clipped()
            } else {
                Theme.raised.overlay {
                    SiteIcon(host: tab.url?.displayHost ?? "", size: 44)
                }
                // The picture is read off the main thread as the card comes up.
                .task { await tab.loadThumbnail() }
            }
        }
        .animation(.easeOut(duration: 0.15), value: tab.thumbnail == nil)
    }
}

/// One tab in the wide grid: its page's top, and under it its name and the way
/// to close it, bare on the dark rather than in a chip over the page.
private struct TabTile: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat
    let isCurrent: Bool
    let open: () -> Void
    let close: () -> Void
    var closeAll: (() -> Void)? = nil
    var split: (() -> Void)? = nil

    private var isHidden: Bool { tab.isPrivate && PrivacyLock.shared.hides(tab.id) }

    static let labelHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .frame(width: width, height: height)
                .overlay(alignment: .top) { TabPicture(tab: tab, width: width, height: height) }
                .clipShape(.rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08))
                }
                // The tab you were on: a ring clear of the card, which any page's
                // colour could swallow if it lay on it.
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(Theme.ink.opacity(0.8), lineWidth: 2)
                            .padding(-4)
                    }
                }
                .contentShape(.rect(cornerRadius: 18))
                .onTapGesture(perform: open)
                .contextMenu {
                    if let split, !isHidden {
                        Button(action: split) { Label("Open in Split View", image: "phosphor/split") }
                    }
                    Button(role: .destructive, action: close) { Label("Close Tab", image: "phosphor/close") }
                    if let closeAll {
                        Button(role: .destructive, action: closeAll) { Label("Close All Tabs", image: "phosphor/close") }
                    }
                }
            HStack(spacing: 8) {
                SiteIcon(host: isHidden ? "" : tab.url?.displayHost ?? "", size: 18)
                if tab.isPrivate {
                    Glyph(.eyeClosed, size: 15).foregroundStyle(Theme.secondaryInk)
                }
                if !isHidden {
                    Text(tab.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Glyph(.close, size: 14, weight: 2)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 44, height: TabTile.labelHeight - 6)
                        .contentShape(.rect)
                }
                .buttonStyle(GlyphButtonStyle())
                .accessibilityLabel("Close tab")
            }
            .padding(.leading, 4)
            .frame(width: width)
            .contentShape(.rect)
            .onTapGesture(perform: open)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isHidden ? "Private tab, locked" : tab.displayTitle)
    }
}

/// A pan that only starts on a mostly-upward drag. Done in UIKit because a
/// SwiftUI drag on each card would swallow the carousel's sideways scrolling.
private struct UpwardPan: UIGestureRecognizerRepresentable {
    let notBefore: Date
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.notBefore = notBefore
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: pan.view).y
        switch pan.state {
        case .changed: changed(translation)
        case .ended, .cancelled: ended(translation, pan.velocity(in: pan.view).y)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var notBefore = Date.distantPast

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard Date.now >= notBefore, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.2
        }
    }
}

// MARK: roko's screens

private extension RecentScreen.Kind {
    var glyph: Glyph.Kind {
        switch self {
        case .todos: .todo
        case .feed: .news
        case .shopping: .basket
        case .readLater: .readLater
        case .answer: .browse
        }
    }

    /// Things to tick off, drawn with the ring they have on their screen.
    var isList: Bool { self == .todos || self == .shopping }

    var empty: String {
        switch self {
        case .todos: "Nothing left to do"
        case .shopping: "Nothing on the list"
        case .feed: "All read"
        case .readLater: "Nothing to read"
        case .answer: ""
        }
    }
}

/// What a screen's card shows: its name or question, and the first few things on it as you
/// left it. Text, set as the screen sets it, on the screen's own paper.
private struct ScreenFace: View {
    let screen: RecentScreen
    let width: CGFloat
    let height: CGFloat
    /// A tile in the wide grid: smaller type for a shorter card.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(screen.kind == .answer ? screen.title : screen.kind.name)
                .font(.system(size: screen.kind == .answer ? (compact ? 16 : 21) : (compact ? 20 : 30), weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .padding(.bottom, compact ? 2 : 8)
            if screen.lines.isEmpty {
                Text(screen.kind.empty)
                    .font(.system(size: compact ? 13 : 16))
                    .foregroundStyle(Theme.secondaryInk)
            }
            ForEach(Array(screen.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    if screen.kind.isList {
                        // On the first line's middle: 16-point type stands about 21 points tall.
                        Circle()
                            .strokeBorder(Theme.secondaryInk.opacity(0.7), lineWidth: 1.5)
                            .frame(width: compact ? 12 : 15, height: compact ? 12 : 15)
                            .padding(.top, compact ? 2.5 : 3)
                    }
                    Text(line)
                        .font(.system(size: compact ? 13 : 16))
                        .foregroundStyle(screen.kind == .answer ? Theme.secondaryInk : Theme.ink)
                        .lineLimit(screen.kind == .answer ? 4 : 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 14 : 22)
        .padding(.top, compact ? 14 : 30)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Theme.panel)
        // What doesn't fit fades into the paper rather than being cut through a line.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height * 0.18)
            }
        }
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }
}

/// A screen in the carousel, built like a tab's card: its name and close above, the card
/// under them, thrown up to close.
private struct ScreenCard: View {
    let screen: RecentScreen
    let width: CGFloat
    let height: CGFloat
    let titleWidth: CGFloat
    let isFocused: Bool
    var isBehind = false
    var overlaps = true
    var showsNeighbourIcon = false
    var throwsFrom = Date.distantPast
    let open: () -> Void
    let close: () -> Void

    @State private var throwOffset: CGFloat = 0
    private let closeDistance: CGFloat = 140
    private var corner: CGFloat { min(34, width * 0.16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            card
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(screen.kind == .answer ? "Browse for Me: \(screen.title)" : screen.kind.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Close", close)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isFocused || showsNeighbourIcon {
                Glyph(screen.kind.glyph, size: 18).foregroundStyle(Theme.ink)
            }
            if isFocused {
                Text(screen.kind.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if isFocused {
                Button(action: close) {
                    Glyph(.close, size: 14, weight: 2)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(GlyphButtonStyle())
                .padding(.trailing, -15)
                .accessibilityLabel("Close")
                .transition(.opacity)
            }
        }
        .frame(width: titleWidth, height: 28, alignment: .leading)
        .padding(.leading, 4)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .opacity(isBehind ? 0 : 1 + throwOffset / 200)
        .animation(.easeOut(duration: 0.18), value: isBehind)
    }

    private var card: some View {
        ScreenFace(screen: screen, width: width, height: height)
            .clipShape(.rect(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(overlaps ? 0.35 : 0), radius: 8, x: -5, y: 0)
            .contentShape(.rect(cornerRadius: corner))
            .onTapGesture(perform: open)
            .contextMenu {
                Button(role: .destructive, action: close) { Label("Close", image: "phosphor/close") }
            }
            .offset(y: throwOffset)
            .opacity(1 + throwOffset / 700)
            .sensoryFeedback(.impact(weight: .light), trigger: throwOffset < -closeDistance) { _, past in past }
            .gesture(UpwardPan(
                notBefore: throwsFrom,
                changed: { throwOffset = min(0, $0) },
                ended: { translation, velocity in
                    if -translation > closeDistance || velocity < -900 {
                        withAnimation(.easeIn(duration: 0.18)) { throwOffset = -1000 } completion: { close() }
                    } else {
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { throwOffset = 0 }
                    }
                }))
    }
}

/// A screen in the wide grid, as a tab's tile is: the card, and under it its name and close.
private struct ScreenTile: View {
    let screen: RecentScreen
    let width: CGFloat
    let height: CGFloat
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ScreenFace(screen: screen, width: width, height: height, compact: true)
                .clipShape(.rect(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)) }
                .contentShape(.rect(cornerRadius: 18))
                .onTapGesture(perform: open)
                .contextMenu {
                    Button(role: .destructive, action: close) { Label("Close", image: "phosphor/close") }
                }
            HStack(spacing: 8) {
                Glyph(screen.kind.glyph, size: 16).foregroundStyle(Theme.ink)
                Text(screen.kind.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: close) {
                    Glyph(.close, size: 14, weight: 2)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 44, height: TabTile.labelHeight - 6)
                        .contentShape(.rect)
                }
                .buttonStyle(GlyphButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.leading, 4)
            .frame(width: width)
            .contentShape(.rect)
            .onTapGesture(perform: open)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(screen.kind == .answer ? "Browse for Me: \(screen.title)" : screen.kind.name)
    }
}
