import SwiftUI

/// The only chrome on screen while browsing. Swipe up for tabs, sideways to
/// switch tabs; it gets out of the way while you scroll down a page and comes
/// back as soon as you scroll up.
struct BottomBar: View {
    @Environment(BrowserModel.self) private var browser
    /// Lying in the band under the page, on its colour, with no
    /// surface of its own. The band folds it away; the card's edge shows loading.
    var docked = false
    /// Where the + capsule is on screen, for the launcher to grow out of.
    @State private var capsuleFrame: CGRect = .zero
    /// Tabs switched by swiping the bar; each one ticks.
    @State private var switches = 0
    /// Swiped at the first or last tab: no further to go, felt as a stop.
    @State private var stops = 0
    /// The swipe on the bar so far: its keys lean with the finger, and spring back.
    @GestureState(reset: { _, transaction in
        transaction.animation = UIAccessibility.isReduceMotionEnabled ? nil : .spring(duration: 0.3, bounce: 0.2)
    }) private var swipe = BarSwipe()

    var body: some View {
        Group {
            if !browser.isBarCollapsed || browser.selectedTab == nil {
                expanded
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, docked ? 0 : Theme.gutter)
        .padding(.bottom, docked ? 0 : 4)
        // Clear of the card by what it leaves above the home indicator; a live row
        // above has its own air.
        .padding(.top, docked && browser.liveItems.isEmpty ? 5 : 0)
        .animation(.snappy(duration: 0.28), value: browser.isBarCollapsed)
        .animation(.snappy(duration: 0.28), value: browser.showsLaunchField)
    }

    /// Arc's layout: the bar is about starting something new. Tabs on the left,
    /// a wide + in the middle, and everything about the current page behind ⌃.
    private var expanded: some View {
        HStack(spacing: 0) {
            // On a page opened from Saved, back: through the tab's pages, then to the list.
            // Swipe up still has the tabs.
            Button {
                if let fromSaved {
                    if fromSaved.canGoBack { fromSaved.webView?.goBack() } else { browser.returnToSaved(from: fromSaved) }
                } else {
                    browser.showTabs()
                }
            } label: {
                Group {
                    if fromSaved != nil {
                        Glyph(.back, size: docked ? 20 : 18, weight: 2)
                            // Its ink as far from the edge as the chevron's on the right.
                            .padding(.leading, docked ? -6 : 0)
                    } else {
                        TabThumbnails(tabs: recentTabs, count: browser.tabs.count, quiet: docked)
                    }
                }
                    // Docked, the two ends sit the same visible distance from the edges,
                    // whatever their widths: the fan's ink is 32 wide, the chevron's 16.
                    .frame(width: docked ? 32 : nil, alignment: .leading)
                    .padding(.leading, docked ? Self.dockedInset : 0)
                    .frame(width: docked ? 72 : 64, height: Theme.barHeight, alignment: docked ? .leading : .center)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel(fromSaved.map { $0.canGoBack ? "Back" : "Back to Saved" } ?? "Tabs, \(browser.tabs.count) open")
            // Hold: close them all, with Undo in the switcher that opens.
            .contextMenu {
                let closing = browser.tabsToCloseAll.count
                if closing > 0 {
                    Button(role: .destructive) { browser.closeAllTabs() } label: {
                        Label(closing == 1 ? "Close 1 Tab" : "Close \(closing) Tabs", image: "phosphor/close")
                    }
                }
            }

            Spacer(minLength: 8)

            // Tap: the launcher. Hold: speak, and let go.
            Group {
                ZStack {
                    // On a private tab it says so, as what tapping does: a private search.
                    Group {
                        if launchField {
                            HStack(spacing: 8) {
                                Glyph(isPrivate ? .eyeClosed : .search, size: 17)
                                Text(isPrivate ? "Private search" : "Search")
                                    .font(.system(size: 15))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            // On the band's capsule the grey fell to about 3:1; this is the bar's main label.
                            .foregroundStyle(docked ? Color.white.opacity(0.72) : Theme.secondaryInk)
                            .padding(.horizontal, 14)
                            .transition(.opacity)
                        } else if let site {
                            // Which site this is, always in view: a look-alike page shows its real name here.
                            HStack(spacing: 6) {
                                if isPrivate {
                                    Glyph(.eyeClosed, size: 17)
                                        .offset(y: 1.5)
                                }
                                Text(site)
                                    .font(.system(size: 15))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(docked ? Color.white.opacity(0.72) : Theme.secondaryInk)
                            .padding(.horizontal, 14)
                            .transition(.opacity)
                        } else if isPrivate {
                            HStack(spacing: 6) {
                                // Centred on the word's lowercase letters, not its
                                // capitals: measured, it sat 1.3 points high.
                                Glyph(.eyeClosed, size: 17)
                                    .offset(y: 1.5)
                                Text("Private").font(.system(size: 15, weight: .semibold))
                            }
                            .transition(.opacity)
                        } else {
                            Glyph(.plus, size: 22, weight: 2)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: isPrivate)
                    .animation(.easeOut(duration: 0.2), value: launchField)
                    .animation(.easeOut(duration: 0.2), value: site)
                    .opacity(browser.voiceListening ? 0 : 1)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .opacity(browser.voiceListening ? 1 : 0)
                }
                .animation(.snappy(duration: 0.15), value: browser.voiceListening)
                    .frame(width: wide ? nil : 104, height: 38)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .background {
                        // Becomes the launcher's field: there only while the launcher isn't,
                        // and only on a page (a screen over it has its own bar).
                        // Hidden while the launcher's field stands in its place.
                        // Docked it stays, and fades with the bar: it used to return
                        // only after the fade, popping in around a + already there.
                        if docked || browser.panel != .command || !onPage {
                            // Docked, the band's colour shows through it.
                            Capsule().fill(docked ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(Theme.raised))
                                // Held: roko's orange fills it from the left as the hold
                                // counts, so it's clear something is about to happen.
                                .overlay(alignment: .leading) {
                                    GeometryReader { proxy in
                                        Theme.accent.opacity(0.35)
                                            .frame(width: proxy.size.width * holdFill)
                                    }
                                    .clipShape(.capsule)
                                }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { capsuleFrame = $0 }
                    .contentShape(.capsule)
            }
            .scaleEffect(browser.voiceListening ? 1.06 : 1)
            .animation(.snappy(duration: 0.2), value: browser.voiceListening)
            // Takes the room from the spacers either side of it.
            .layoutPriority(wide ? 1 : 0)
            .gesture(holdToTalk.updating($touching) { _, touching, _ in touching = true })
            // A hold cut short (an alert, a call, Control Center) never ends: reset it
            // once the touch is gone, so the next hold works and the microphone stops.
            .onChange(of: touching) { _, now in
                guard !now else { return }
                DispatchQueue.main.async {
                    guard pressedAt != nil else { return }  // ended normally meanwhile
                    withAnimation(.easeOut(duration: 0.15)) { holdFill = 0 }
                    holdTask?.cancel()
                    pressedAt = nil
                    swiped = false
                    if browser.voiceListening { browser.endVoice() }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(launchField ? (isPrivate ? "Private search or address" : "Search or enter address")
                                : site.map { "On \($0). Search or enter address" } ?? (isPrivate ? "Private search" : "New tab"))
            .accessibilityHint(Preferences.holdToTalk ? "Hold to speak" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { browser.showCommandBar() }

            Spacer(minLength: 8)

            Button { browser.panel = .tools } label: {
                Glyph(.chevronUp, size: docked ? 20 : 18, weight: 2)
                    .frame(width: 38, height: 38)
                    .background(docked ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.raised), in: .circle)
                    // The glyph's ink is 11 inside its 38-point circle.
                    .padding(.trailing, docked ? Self.dockedInset - 11 : 0)
                    .frame(width: docked ? 72 : 64, height: Theme.barHeight, alignment: docked ? .trailing : .center)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(browser.selectedTab == nil)
            // No page, no page menu: in the band it would be a dead key.
            .opacity(docked && browser.selectedTab == nil ? 0 : 1)
            .accessibilityLabel("Page menu")
        }
        .offset(swipe.lean)
        .frame(height: docked ? Theme.barHeight : Theme.barHeight + 8)
        .overlay(alignment: .bottom) {
            if !docked { ProgressLine(tab: browser.selectedTab) }
        }
        .modifier(BarSurface(on: !docked))
        // With no surface, the gaps between the keys take the swipes too.
        .contentShape(.rect)
        // Alongside the + capsule's own hold, not over it: as a high-priority
        // gesture it held every touch until it knew it wasn't a swipe, so a
        // hold on + never reached the capsule.
        .simultaneousGesture(swipes)
        .sensoryFeedback(.selection, trigger: switches)
        // Far enough that letting go will do it.
        .sensoryFeedback(.impact(weight: .light), trigger: swipe.willAct) { _, will in will }
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: stops)
    }

    static let dockedInset: CGFloat = 30


    @State private var pressedAt: Date?
    @GestureState private var touching = false
    @State private var holdTask: Task<Void, Never>?
    @State private var swiped = false
    /// How far the hold has counted, 0 to 1, drawn as the capsule's fill.
    @State private var holdFill: CGFloat = 0

    /// A tap opens the launcher; held past a third of a second, it listens
    /// until the finger lifts.
    private var holdToTalk: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A swipe across the bar (to switch tabs) isn't a hold or a tap.
                if hypot(value.translation.width, value.translation.height) > 14 {
                    if !swiped { withAnimation(.easeOut(duration: 0.15)) { holdFill = 0 } }
                    holdTask?.cancel()
                    swiped = true
                }
                guard pressedAt == nil else { return }
                pressedAt = .now
                guard Preferences.holdToTalk else { return }
                holdTask = Task {
                    // Not on a tap: the fill starts only once the finger has
                    // stayed down longer than a tap does (it flashed orange
                    // under every tap that opened the bar).
                    let ramp = UIImpactFeedbackGenerator(style: .rigid)
                    ramp.prepare()
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: 0.24)) { holdFill = 1 }
                    // Taps that grow as the hold counts, so it's felt filling up.
                    for (step, intensity) in [0.3, 0.55, 0.8].enumerated() {
                        if step > 0 { try? await Task.sleep(for: .milliseconds(80)) }
                        guard !Task.isCancelled else { return }
                        ramp.impactOccurred(intensity: intensity)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { holdFill = 0 }
                    browser.launcherOrigin = capsuleFrame
                    browser.startVoice()
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) { holdFill = 0 }
                holdTask?.cancel()
                pressedAt = nil
                defer { swiped = false }
                if browser.voiceListening {
                    browser.endVoice()
                } else if swiped {
                    return
                } else if browser.panel != .command {
                    browser.launcherOrigin = capsuleFrame
                    browser.showCommandBar()
                }
            }
    }

    private var isPrivate: Bool { browser.selectedTab?.isPrivate == true }

    /// The tab on screen, when it was opened from Saved.
    private var fromSaved: BrowserTab? { browser.selectedTab.flatMap { $0.savedPlace == nil ? nil : $0 } }

    /// With nothing open, the bar is only for this: it's a search field, always.
    private var launchField: Bool { browser.selectedTab == nil ? docked : browser.showsLaunchField }

    /// The site the page on screen is from, in the capsule once it's no longer the search field.
    private var site: String? {
        guard !launchField, let host = browser.selectedTab?.url?.displayHost, !host.isEmpty else { return nil }
        return host
    }

    /// The capsule holds words, not just the +.
    private var wide: Bool { launchField || site != nil }

    private var onPage: Bool {
        browser.screenBeside || ![.today, .todos, .shopping, .readLater, .feed].contains(browser.panel) && browser.browseForMe == nil && browser.summary == nil && browser.digest == nil
    }

    private var recentTabs: [BrowserTab] {
        // The tab on screen in front, whenever it was last marked active.
        Array(browser.tabs.sorted { a, b in
            if (a.id == browser.selectedID) != (b.id == browser.selectedID) { return a.id == browser.selectedID }
            return a.lastActive > b.lastActive
        }.prefix(2))
    }

}

/// The loading line along the bar. A view of its own, so each step of a
/// page's progress redraws this and not the whole bar.
private struct ProgressLine: View {
    let tab: BrowserTab?

    var body: some View {
        if let tab, tab.isLoading {
            GeometryReader { proxy in
                let track = proxy.size.width
                Capsule()
                    .fill(Theme.accent.opacity(0.75))
                    .frame(width: max(6, track * tab.progress), height: 2)
                    .animation(.easeOut(duration: 0.25), value: tab.progress)
            }
            .frame(height: 2)
            .padding(.horizontal, 22)
            .padding(.bottom, 5)
            .transition(.opacity)
        }
    }
}

extension BottomBar {

    private var swipes: some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($swipe) { value, swipe, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                if dy < 0, abs(dy) > abs(dx) {
                    swipe = BarSwipe(lean: CGSize(width: 0, height: max(dy * 0.3, -14)), willAct: dy < -Self.swipeUp)
                } else if abs(dx) > abs(dy) {
                    let free = hasNeighbor(toward: dx)
                    let reach: CGFloat = free ? 24 : 10
                    let lean = min(max(dx * (free ? 0.3 : 0.1), -reach), reach)
                    swipe = BarSwipe(lean: CGSize(width: lean, height: 0), willAct: free && abs(dx) > Self.swipeAcross)
                } else {
                    swipe = BarSwipe()
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if dy < -Self.swipeUp, abs(dy) > abs(dx) {
                    browser.showTabs()
                } else if abs(dx) > Self.swipeAcross, abs(dx) > abs(dy) {
                    guard hasNeighbor(toward: dx) else {
                        stops += 1
                        return
                    }
                    withAnimation(.snappy) { browser.selectNeighbor(offset: dx < 0 ? 1 : -1) }
                    switches += 1
                }
            }
    }

    private static let swipeUp: CGFloat = 40
    private static let swipeAcross: CGFloat = 60

    /// A tab beyond this one, the way a swipe of this sign goes.
    private func hasNeighbor(toward dx: CGFloat) -> Bool {
        guard let index = browser.tabs.firstIndex(where: { $0.id == browser.selectedID }) else { return false }
        return browser.tabs.indices.contains(index + (dx < 0 ? 1 : -1))
    }
}

/// A swipe on the bar, as far as it's gone.
private struct BarSwipe {
    var lean = CGSize.zero
    var willAct = false
}

/// The floating bar's panel; docked, it sits straight on the band.
private struct BarSurface: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.barSurface(cornerRadius: Theme.barRadius)
        } else {
            // On black whichever look roko has, so its keys take their dark colours.
            content.foregroundStyle(Theme.ink).environment(\.colorScheme, .dark)
        }
    }
}

/// Your two most recent tabs as tiny fanned cards, like Arc. Falls back to
/// the tabs glyph until there are snapshots to show.
private struct TabThumbnails: View {
    let tabs: [BrowserTab]
    let count: Int
    /// Docked: a size smaller, the back card a step down, so it stays behind the
    /// front one and the fan doesn't outweigh the capsule.
    var quiet = false

    var body: some View {
        Group {
            if tabs.allSatisfy({ $0.thumbnail == nil || $0.thumbnailIsBlank }) {
                TabsGlyph(count: count)
            } else {
                ZStack {
                    // By tab, not by picture: a tab with no picture yet moved someone
                    // else's to the front, and the card showed the wrong page.
                    ForEach(Array(tabs.prefix(2).enumerated().reversed()), id: \.element.id) { index, tab in
                        card(tab)
                            .frame(width: quiet ? 20 : 22, height: quiet ? 27 : 30, alignment: .top)
                            .brightness(quiet && index == 1 ? -0.35 : 0)
                            .clipShape(.rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.edge, lineWidth: 1))
                            .rotationEffect(.degrees(index == 0 ? 7 : -9))
                            .offset(x: index == 0 ? 5 : -5, y: index == 0 ? -1 : 2)
                    }
                }
            }
        }
        // Small pictures, read off the main thread: the full ones are ten megabytes each.
        .task(id: tabs.map(\.id)) { for tab in tabs { await tab.loadThumbnail() } }
    }

    /// Its picture, or with none worth showing, the site's own colour: never a blank sheet.
    @ViewBuilder
    private func card(_ tab: BrowserTab) -> some View {
        if let picture = tab.thumbnail, !tab.thumbnailIsBlank {
            Image(uiImage: picture).resizable().scaledToFill()
        } else {
            Rectangle().fill(tab.topColor?.cardShade ?? Color(white: 0.36))
        }
    }
}

/// The tabs glyph, a little larger, with the open-tab count set inside its front card.
private struct TabsGlyph: View {
    let count: Int
    private let size: CGFloat = 24

    var body: some View {
        Glyph(.tabs, size: size)
            .overlay(alignment: .topLeading) {
                if count > 0 {
                    // Phosphor's front card spans 24...200 × 72...216 of its 256 grid.
                    Text(count > 99 ? "∞" : "\(count)")
                        .font(.system(size: count > 9 ? 8 : 10, weight: .semibold))
                        .fixedSize()
                        .position(x: 112 / 256 * size, y: 144 / 256 * size)
                }
            }
            .frame(width: size, height: size)
    }
}

struct BarButton: View {
    let glyph: Glyph.Kind
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(glyph)
                .frame(width: 48, height: Theme.barHeight)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Pressing dims the glyph; nothing moves or scales. Hierarchical styles, so on
/// glass the system keeps it legible and on our panels it resolves to Theme.ink.
struct GlyphButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? (configuration.isPressed ? HierarchicalShapeStyle.secondary : .primary) : .tertiary)
    }
}
