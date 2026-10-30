import SwiftData
import SwiftUI

/// The tab switcher, after Arc: your tabs as big overlapping page cards that
/// scroll sideways, the focused one's name above it. Tap a card to open it,
/// throw it up to close it. Pull the bottom row up to go back to your page.
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
            let cardWidth = (proxy.size.width * 0.76).rounded()
            // Each card shows this much before the next one covers it.
            // Most of the focused card shows; the next one just overlaps its edge.
            let stride = (proxy.size.width * 0.66).rounded()
            let cardHeight = min(cardWidth * 1.95, proxy.size.height - 230)

            VStack(spacing: 0) {
                // Pins live above the address field, not here.
                Spacer(minLength: 0)

                if browser.tabs.isEmpty {
                    Text("No open tabs")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(height: cardHeight + 40)
                } else {
                    carousel(cardWidth: cardWidth, stride: stride, cardHeight: cardHeight,
                             screenWidth: proxy.size.width)
                }

                Spacer(minLength: 0)
                reopenOffer
                bottomRow
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
        .animation(.snappy(duration: 0.3), value: closedHere)
        .animation(.snappy(duration: 0.3), value: browser.recentlyClosed.count)
    }

    // MARK: Cards

    private func carousel(cardWidth: CGFloat, stride: CGFloat, cardHeight: CGFloat,
                          screenWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: stride - cardWidth) {
                let focusedIndex = browser.tabs.firstIndex { $0.id == focused } ?? 0
                ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabCard(tab: tab, width: cardWidth, height: cardHeight,
                            titleWidth: stride - 16, isFocused: tab.id == focused,
                            isBehind: index < focusedIndex,
                            open: { open(tab) },
                            close: { close(tab) },
                            split: canSplit(with: tab) ? { browser.panel = .none; browser.startSplit(with: tab) } : nil)
                    // As in Arc: tabs to the left sink back into a stack behind
                    // the focused card, smaller and tucked under it; the next tab
                    // on the right stays full size, laid over it. Drawn by the
                    // scroll view itself, so it costs nothing per frame in code.
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        let back = max(0, -phase.value)
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
        if !tab.isPrivate, tab.url != nil { closedHere = true }
    }

    /// The tab just thrown away, a tap from coming back with its history.
    /// Built like the copied-link offer: what it is, then one word to act.
    @ViewBuilder
    private var reopenOffer: some View {
        if closedHere, let closed = browser.recentlyClosed.last {
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    SiteIcon(host: closed.url.displayHost, size: 18)
                    Text(closed.url.displayHost)
                        .font(.system(size: 15, weight: .medium))
                }
                Button("Reopen") {
                    browser.reopenClosedTab()
                    closedHere = false
                }
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
    }

    /// The selected page, blurred far out of focus: the switcher takes on the
    /// colour of where you were, the way Arc's does.
    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            Theme.canvas
            if let snapshot = browser.selectedTab?.snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60, opaque: true)
                    // Low enough that a white page tints the dark rather than greying it.
                    .opacity(0.14)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Bottom row

    private var bottomRow: some View {
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
    let open: () -> Void
    let close: () -> Void
    /// With the tab on screen, split; nil for the tab on screen itself.
    var split: (() -> Void)? = nil

    @State private var throwOffset: CGFloat = 0
    private let closeDistance: CGFloat = 140
    private let corner: CGFloat = 34

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
            .shadow(color: .black.opacity(0.35), radius: 8, x: -5, y: 0)
            .contentShape(.rect(cornerRadius: corner))
            .onTapGesture(perform: open)
            .contextMenu {
                if let split, !isHidden {
                    Button(action: split) { Label("Open in Split View", image: "phosphor/split") }
                }
                Button(role: .destructive, action: close) { Label("Close Tab", image: "phosphor/close") }
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

    @ViewBuilder
    private var preview: some View {
        if isHidden {
            Theme.raised.overlay {
                Glyph(.lock, size: 40).foregroundStyle(Theme.secondaryInk)
            }
        } else if let snapshot = tab.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height, alignment: .top)
                .clipped()
        } else {
            Theme.raised.overlay {
                SiteIcon(host: tab.url?.displayHost ?? "", size: 44)
            }
        }
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
