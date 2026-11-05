import SwiftData
import SwiftUI

/// The tab switcher, after Arc: your tabs as big overlapping page cards that
/// scroll sideways, the focused one's name above it. Tap a card to open it,
/// throw it up to close it. Pull the bottom row up to go back to your page.
/// On an open iPhone Duo there's room for more: a grid of wide cards, each page's top whole.
struct TabStackView: View {
    @Environment(BrowserModel.self) private var browser
    @Query private var todos: [Todo]
    /// The card centred in the carousel; follows scrolling.
    @State private var focused: BrowserTab.ID?
    /// How far the whole switcher has been pulled up (negative), following the finger.
    @State private var lift: CGFloat = 0
    /// A tab was thrown away while the switcher is open: offer it back.
    @State private var closedHere = false

    private let returnThreshold: CGFloat = 90

    var body: some View {
        GeometryReader { proxy in
            // Turned sideways the cards stay upright and narrow: several at
            // once to swipe through, rather than one wide strip of a page.
            let sideways = proxy.size.width > proxy.size.height
            let cardHeight = sideways ? proxy.size.height - 130 : min((proxy.size.width * 0.76).rounded() * 1.95, proxy.size.height - 230)
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

                if browser.tabs.isEmpty {
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
                reopenOffer
                bottomRow(compact: isGrid)
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12))
            }
        }
        .background { backdrop }
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .dark)
        .offset(y: lift)
        .opacity(1 + lift / 600)
        // A thrown-away tab lands with a thud.
        .sensoryFeedback(.impact(weight: .medium), trigger: browser.tabs.count) { old, new in new < old }
        .onAppear {
            focused = browser.selectedID ?? browser.tabs.last?.id
            closedHere = false
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
                TileGrid(columns: columns, gap: gap) {
                    ForEach(browser.tabs) { tab in
                        TabTile(tab: tab, width: cardWidth, height: cardHeight,
                                isCurrent: tab.id == browser.selectedID,
                                open: { open(tab) },
                                close: { close(tab) },
                                closeAll: browser.tabs.count > 1 ? { browser.closeAllTabs() } : nil,
                                split: canSplit(with: tab) ? { browser.panel = .none; browser.startSplit(with: tab) } : nil)
                        .id(tab.id)
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
            .onAppear { reader.scrollTo(browser.selectedID, anchor: .center) }
            .animation(.snappy(duration: 0.3), value: browser.tabs.map(\.id))
        }
    }

    // MARK: Cards

    private func carousel(cardWidth: CGFloat, stride: CGFloat, cardHeight: CGFloat,
                          screenWidth: CGFloat, stacks: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: stride - cardWidth) {
                let focusedIndex = browser.tabs.firstIndex { $0.id == focused } ?? 0
                ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabCard(tab: tab, width: cardWidth, height: cardHeight,
                            titleWidth: (stacks ? stride : cardWidth) - 16, isFocused: tab.id == focused,
                            isBehind: stacks && index < focusedIndex, overlaps: stacks,
                            open: { open(tab) },
                            close: { close(tab) },
                            closeAll: browser.tabs.count > 1 ? { browser.closeAllTabs(); focused = browser.selectedID ?? browser.tabs.last?.id } : nil,
                            split: canSplit(with: tab) ? { browser.panel = .none; browser.startSplit(with: tab) } : nil)
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
        .animation(.snappy(duration: 0.3), value: browser.tabs.map(\.id))
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

    private func close(_ tab: BrowserTab) {
        // Keep a neighbour centred so the carousel doesn't jump to the start.
        if focused == tab.id, let index = browser.tabs.firstIndex(where: { $0.id == tab.id }) {
            let neighbours = browser.tabs.indices.filter { $0 != index }
            focused = neighbours.min { abs($0 - index) < abs($1 - index) }.map { browser.tabs[$0].id }
        }
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
                Text(group.tabs.count == 1 ? "1 tab closed" : "\(group.tabs.count) tabs closed")
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
                if let snapshot = browser.selectedTab?.snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 60, opaque: true)
                        // Low enough that a white page tints the dark rather than greying it.
                        .opacity(0.14)
                }
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: Bottom row

    private func bottomRow(compact: Bool) -> some View {
        HStack(spacing: 0) {
            roundButton(.eyeClosed, "New private tab") {
                browser.showCommandBar(mode: .privateTab)
            }
            Spacer(minLength: 8)
            roundButton(.today, "Today") { browser.panel = .today }
            Spacer(minLength: 8)
            Button { browser.showCommandBar() } label: {
                Glyph(.plus, size: 22, weight: 2)
                    .frame(width: 104, height: 48)
                    .background(Theme.raised, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.edge))
                    .contentShape(.capsule)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("New tab")
            Spacer(minLength: 8)
            todoButton
            Spacer(minLength: 8)
            roundButton(.settings, "Settings") { browser.panel = .settings }
        }
        .padding(.horizontal, Theme.gutter + 8)
        .padding(.top, 16)
        // On the wide grid, together under it rather than flung to the edges.
        .frame(maxWidth: compact ? 500 : nil)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .highPriorityGesture(pullUp)
    }

    private func roundButton(_ glyph: Glyph.Kind, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: 20)
                .frame(width: 48, height: 48)
                .background(Theme.raised, in: .circle)
                .overlay(Circle().strokeBorder(Theme.edge))
                .contentShape(.circle)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }

    /// To-do, with how many are left today on its corner while any are.
    private var todoButton: some View {
        let left = todos.filter(\.isDueNow).count
        return Button { browser.panel = .todos } label: {
            Group {
                if left > 0 { TodoIcon(left: left, size: 22) } else { Glyph(.todo, size: 20) }
            }
            .frame(width: 48, height: 48)
            .background(Theme.raised, in: .circle)
            .overlay(Circle().strokeBorder(Theme.edge))
            .contentShape(.circle)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(left > 0 ? "To-do, \(left) left for today" : "To-do")
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
            SiteIcon(host: isHidden ? "" : tab.url?.displayHost ?? "", size: 20)
            if tab.isPrivate {
                Glyph(.eyeClosed, size: 15).foregroundStyle(Theme.secondaryInk)
            }
            if isFocused, !isHidden {
                Text(tab.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        // The focused title is centred over the part of its card you can see;
        // a neighbour shows just its icon. Tabs stacked behind show nothing.
        .frame(width: titleWidth, height: 28, alignment: isFocused ? .center : .leading)
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
            .gesture(UpwardPan(
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
        if tab.isPrivate && PrivacyLock.shared.hides(tab.id) {
            Theme.raised.overlay {
                Glyph(.lock, size: 40).foregroundStyle(Theme.secondaryInk)
            }
        } else if let snapshot = tab.snapshot {
            Image(uiImage: snapshot)
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
        }
    }
}

/// Row under row. One layout for all of them, so a card slides to
/// its new place when one before it closes.
private struct TileGrid: Layout {
    let columns: Int
    let gap: CGFloat
    private let rowGap: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let tile = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        let rows = CGFloat((subviews.count + columns - 1) / columns)
        return CGSize(width: tile.width * CGFloat(columns) + gap * CGFloat(columns - 1),
                      height: tile.height * rows + rowGap * (rows - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tile = subviews.first?.sizeThatFits(.unspecified) else { return }
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index % columns) * (tile.width + gap)
            let y = bounds.minY + CGFloat(index / columns) * (tile.height + rowGap)
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
        }
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
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
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
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.2
        }
    }
}
