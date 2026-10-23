import SwiftData
import SwiftUI

struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var barTop: CGFloat = 0
    /// How far a pinch on the page has shrunk it toward a summary (1 = not at all).
    @State private var pinchScale: CGFloat = 1

    var body: some View {
        @Bindable var browser = browser

        ZStack {
            // Behind the page: the site's top colour in the status-bar strip
            // only (as in Safari), and its own background below, so no header
            // colour ever shows at the bottom of the screen.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    (pinchScale < 1 || browser.summaryCoversPage && browser.summary?.isClosing != true ? Theme.canvas : browser.selectedTab?.topColor.map(Color.init) ?? Theme.canvas)
                        .frame(height: proxy.safeAreaInsets.top)
                    (pinchScale < 1 || browser.summaryCoversPage && browser.summary?.isClosing != true ? Theme.canvas : browser.selectedTab?.bottomColor.map(Color.init) ?? Theme.canvas)
                }
                .ignoresSafeArea()
            }
            .animation(.easeOut(duration: 0.2), value: browser.selectedTab?.topColor)

            if let tab = browser.selectedTab {
                WebViewHost(
                    tab: tab,
                    barTop: barTop,
                    onPinchIn: {
                        // Hand over at the size the fingers left the page; the
                        // summary's card carries on from there.
                        browser.summarize(fromScale: pinchScale)
                    },
                    onPinchChange: { scale in
                        if let scale {
                            browser.preparePinchSnapshot()
                            pinchScale = scale
                        } else if browser.summary == nil {
                            browser.cancelPinchSnapshot()
                            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { pinchScale = 1 }
                        }
                    },
                    onScrollDirection: { down in
                        if browser.isBarCollapsed != down { browser.isBarCollapsed = down }
                    })
                    .ignoresSafeArea(.container, edges: .bottom)
                    // The page itself follows a pinch, shrinking into a card.
                    .clipShape(.rect(cornerRadius: 40 * (1 - pinchScale)))
                    .scaleEffect(pinchScale)
                    .opacity(browser.summaryCoversPage ? 0 : 1)
                    // Once the card has taken over, the hidden page returns to
                    // full size, ready for the card to grow back into it.
                    .onChange(of: browser.summaryCoversPage) { _, covered in
                        if covered { pinchScale = 1 }
                    }

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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The command bar takes the bar's place rather than stacking on top of it.
            BottomBar()
                .opacity(browser.panel == .command || browser.panel == .tabs ? 0 : 1)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
        }
        .overlay {
            if browser.panel == .command {
                CommandBarView()
                    // Quick: it swaps places with the bar, and the keyboard brings the motion.
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
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
            if let model = browser.browseForMe {
                // Full screen, rising from the bar where the question was asked.
                // One identity for every answer, so a follow-up or a reworded
                // question changes the page in place instead of rising again.
                BrowseForMeView(model: model)
                    .id("browse-for-me")
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
            if phase == .background { browser.saveTabs() }
        }
        // Coming back to the app always shows the bar; scrolling hides it again.
        // UIKit's own signal: it arrives whatever wraps the SwiftUI scene.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if browser.isBarCollapsed { browser.isBarCollapsed = false }
        }
        // So does coming back from a summary, an answer or the reader: the
        // pinch or scroll that led there may have folded it away.
        .onChange(of: browser.summary == nil && browser.browseForMe == nil && browser.reader == nil) { _, backOnPage in
            if backOnPage, browser.isBarCollapsed { browser.isBarCollapsed = false }
        }
    }

    /// Text that reads on whatever is behind the status bar.
    private var statusBarStyle: UIStatusBarStyle {
        // The summary and Browse for Me sit on the app's own canvas.
        if browser.summary != nil || browser.browseForMe != nil { return .default }
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
