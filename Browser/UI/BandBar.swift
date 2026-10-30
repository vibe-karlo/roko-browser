import SwiftUI

/// Exploration: the bar as part of the dark band under the page, not a capsule
/// floating over it. The page is a card; under it, on black, three keys of one
/// shape, an outlined rounded square: your tabs with how many, a new tab in the
/// middle, and the page's menu. A sideways swipe across the band switches tabs,
/// a swipe up shows them all. While a page loads, a thin line runs just under
/// the card. Scrolling down folds it away and the card grows to the bottom;
/// scrolling up brings it back.
struct BandBar: View {
    @Environment(BrowserModel.self) private var browser
    @State private var plusFrame: CGRect = .zero
    @State private var switches = 0

    static let height: CGFloat = 50

    private var tab: BrowserTab? { browser.selectedTab }

    var body: some View {
        HStack(spacing: 0) {
            Button { browser.showTabs() } label: {
                BandKey {
                    Text("\(browser.tabs.count)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                }
            }
            .accessibilityLabel("Tabs, \(browser.tabs.count) open")

            Spacer()

            Button {
                browser.launcherOrigin = plusFrame
                browser.showCommandBar(mode: tab?.isPrivate == true ? .privateTab : .newTab)
            } label: {
                BandKey(wide: true) {
                    if tab?.isPrivate == true {
                        Glyph(.eyeClosed, size: 16)
                    } else {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                    }
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { plusFrame = $0 }
            .accessibilityLabel(tab?.isPrivate == true ? "Private search" : "New tab")

            Spacer()

            Button { browser.panel = .tools } label: {
                BandKey {
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .bold))
                }
            }
            .accessibilityLabel("Page menu")
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .contentShape(.rect)
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            if dy < -30, abs(dy) > abs(dx) {
                browser.showTabs()
            } else if abs(dx) > 50, abs(dx) > abs(dy) {
                let before = browser.selectedID
                withAnimation(.snappy) { browser.selectNeighbor(offset: dx < 0 ? 1 : -1) }
                if browser.selectedID != before { switches += 1 }
            }
        })
        .overlay(alignment: .top) { progress }
        .sensoryFeedback(.selection, trigger: switches)
        .environment(\.colorScheme, .dark)
    }

    /// Loading: a thin line along the top of the band, just under the card.
    @ViewBuilder
    private var progress: some View {
        if let tab, tab.isLoading {
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(width: max(8, proxy.size.width * tab.progress), height: 2)
                    .animation(.easeOut(duration: 0.25), value: tab.progress)
            }
            .frame(height: 2)
            .padding(.horizontal, 24)
            .transition(.opacity)
        }
    }
}

/// The band's one key shape: an outlined rounded square (wider for the
/// middle one), white on the black, its tap target the full height of the band.
private struct BandKey<Content: View>: View {
    var wide = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .foregroundStyle(.white)
            .frame(width: wide ? 44 : 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.6), lineWidth: 1.6))
            .frame(width: wide ? 72 : 52, height: BandBar.height)
            .contentShape(.rect)
    }
}
