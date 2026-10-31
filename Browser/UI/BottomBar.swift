import SwiftUI

/// The only chrome on screen while browsing. Swipe up for tabs, sideways to
/// switch tabs; it gets out of the way while you scroll down a page and comes
/// back as soon as you scroll up.
struct BottomBar: View {
    @Environment(BrowserModel.self) private var browser
    /// Turned sideways: a column in the strip beside the page, tabs at the
    /// top, + in the middle, the page menu at the foot. It has its own strip,
    /// so it stays while you scroll.
    var upright = false
    /// Where the + capsule is on screen, for the launcher to grow out of.
    @State private var capsuleFrame: CGRect = .zero
    /// Tabs switched by swiping the bar; each one ticks.
    @State private var switches = 0

    var body: some View {
        Group {
            if upright {
                expanded
            } else if !browser.isBarCollapsed || browser.selectedTab == nil {
                expanded
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, upright ? 0 : Theme.gutter)
        .padding(.bottom, upright ? 0 : 4)
        .animation(.snappy(duration: 0.28), value: browser.isBarCollapsed)
    }

    /// Arc's layout: the bar is about starting something new. Tabs on the left,
    /// a wide + in the middle, and everything about the current page behind ⌃.
    private var expanded: some View {
        let layout = upright ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Button { browser.showTabs() } label: {
                TabThumbnails(tabs: recentTabs, count: browser.tabs.count)
                    .frame(width: upright ? 56 : 64, height: upright ? 64 : Theme.barHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("Tabs, \(browser.tabs.count) open")

            Spacer(minLength: 8)

            // Tap: the launcher. Hold: speak, and let go.
            Group {
                ZStack {
                    // On a private tab it says so, as what tapping does: a private search.
                    Group {
                        if isPrivate && upright {
                            Glyph(.eyeClosed, size: 19)
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
                    .opacity(browser.voiceListening ? 0 : 1)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .opacity(browser.voiceListening ? 1 : 0)
                }
                .animation(.snappy(duration: 0.15), value: browser.voiceListening)
                    .frame(width: upright ? 44 : 104, height: upright ? 96 : 38)
                    .background {
                        // Becomes the launcher's field: there only while the launcher isn't,
                        // and only on a page (a screen over it has its own bar).
                        // Hidden while the launcher's field stands in its place.
                        if browser.panel != .command || !onPage {
                            Capsule().fill(Theme.raised)
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
            .accessibilityLabel(isPrivate ? "Private search" : "New tab")
            .accessibilityHint(Preferences.holdToTalk ? "Hold to speak" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { browser.showCommandBar() }

            Spacer(minLength: 8)

            Button { browser.panel = .tools } label: {
                Glyph(.chevronUp, size: 18, weight: 2)
                    .frame(width: 38, height: 38)
                    .background(Theme.raised, in: .circle)
                    .frame(width: upright ? 56 : 64, height: upright ? 64 : Theme.barHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(browser.selectedTab == nil)
            .accessibilityLabel("Page menu")
        }
        .frame(height: upright ? nil : Theme.barHeight + 8)
        .padding(.vertical, upright ? 18 : 0)
        .overlay(alignment: upright ? .leading : .bottom) { progressLine }
        .modifier(BarSurface(on: !upright))
        // Alongside the + capsule's own hold, not over it: as a high-priority
        // gesture it held every touch until it knew it wasn't a swipe, so a
        // hold on + never reached the capsule.
        .simultaneousGesture(swipes)
        .sensoryFeedback(.selection, trigger: switches)
    }

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

    private var onPage: Bool {
        ![.today, .todos, .shopping, .readLater].contains(browser.panel) && browser.browseForMe == nil && browser.summary == nil && browser.digest == nil
    }

    private var recentTabs: [BrowserTab] {
        Array(browser.tabs.sorted { $0.lastActive > $1.lastActive }.prefix(2))
    }

    @ViewBuilder
    private var progressLine: some View {
        if let tab = browser.selectedTab, tab.isLoading {
            if upright {
                // Down the column's inner edge, beside the page it's loading.
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.accent.opacity(0.75))
                        .frame(width: 2, height: max(6, proxy.size.height * tab.progress))
                        .animation(.easeOut(duration: 0.25), value: tab.progress)
                }
                .frame(width: 2)
                .padding(.vertical, 22)
                .transition(.opacity)
            } else {
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

    private var swipes: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                // Upright, the axes turn: along the column switches tabs, off it opens them.
                let dx = upright ? -value.translation.height : value.translation.width
                let dy = upright ? value.translation.width : value.translation.height
                if dy < -40, abs(dy) > abs(dx) {
                    browser.showTabs()
                } else if abs(dx) > 60, abs(dx) > abs(dy) {
                    let before = browser.selectedID
                    withAnimation(.snappy) { browser.selectNeighbor(offset: dx < 0 ? 1 : -1) }
                    if browser.selectedID != before { switches += 1 }
                }
            }
    }
}

/// The floating bar's panel; upright, the column sits straight on the dark strip.
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

    var body: some View {
        let shots = tabs.compactMap(\.snapshot)
        if shots.isEmpty {
            TabsGlyph(count: count)
        } else {
            ZStack {
                ForEach(Array(shots.prefix(2).enumerated().reversed()), id: \.offset) { index, shot in
                    Image(uiImage: shot)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 30, alignment: .top)
                        .clipShape(.rect(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.edge, lineWidth: 1))
                        .rotationEffect(.degrees(index == 0 ? 7 : -9))
                        .offset(x: index == 0 ? 5 : -5, y: index == 0 ? -1 : 2)
                }
            }
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
