import SwiftUI

/// Exploration: the bar as part of the dark band under the page, not a capsule
/// floating over it. The page is a card; under it, on black, one quiet line:
/// where you are (the site, tap to change the address, swipe to switch tabs),
/// how many tabs, a new tab, and the page's menu. While a page loads, a thin
/// line runs along the card's lower edge. Scrolling down folds it away and the
/// card grows to the bottom; scrolling up brings it back.
struct BandBar: View {
    @Environment(BrowserModel.self) private var browser
    @State private var addressFrame: CGRect = .zero
    @State private var switches = 0

    static let height: CGFloat = 50

    private var tab: BrowserTab? { browser.selectedTab }

    var body: some View {
        HStack(spacing: 6) {
            Button { browser.showTabs() } label: {
                Text("\(browser.tabs.count)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.6), lineWidth: 1.6))
                    .frame(width: 44, height: Self.height)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Tabs, \(browser.tabs.count) open")

            address

            Button {
                browser.launcherOrigin = addressFrame
                browser.showCommandBar(mode: tab?.isPrivate == true ? .privateTab : .newTab)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white, in: .circle)
                    .frame(width: 44, height: Self.height)
                    .contentShape(.rect)
            }
            .accessibilityLabel("New tab")

            Button { browser.panel = .tools } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: .circle)
                    .frame(width: 44, height: Self.height)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Page menu")
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .overlay(alignment: .top) { progress }
        .sensoryFeedback(.selection, trigger: switches)
        .environment(\.colorScheme, .dark)
    }

    /// Where you are: the site, quietly, centred. A tap changes the address;
    /// a sideways swipe moves to the tab beside; a swipe up shows them all.
    private var address: some View {
        let host = tab?.url?.displayHost ?? ""
        return HStack(spacing: 7) {
            if tab?.isPrivate == true {
                Glyph(.eyeClosed, size: 14).foregroundStyle(.white.opacity(0.7))
            } else if !host.isEmpty {
                SiteIcon(host: host, size: 15)
            }
            Text(host.isEmpty ? "Search or enter address" : host)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(host.isEmpty ? .white.opacity(0.5) : .white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(.white.opacity(0.08), in: .capsule)
        .contentShape(.capsule)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { addressFrame = $0 }
        .onTapGesture {
            browser.launcherOrigin = addressFrame
            browser.showCommandBar(prefill: tab?.url?.absoluteString ?? "", mode: .currentTab)
        }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            if dy < -30, abs(dy) > abs(dx) {
                browser.showTabs()
            } else if abs(dx) > 50, abs(dx) > abs(dy) {
                let before = browser.selectedID
                withAnimation(.snappy) { browser.selectNeighbor(offset: dx < 0 ? 1 : -1) }
                if browser.selectedID != before { switches += 1 }
            }
        })
        .accessibilityElement()
        .accessibilityLabel(host.isEmpty ? "Address" : "Address, \(host)")
        .accessibilityHint("Edit the address")
        .accessibilityAddTraits(.isButton)
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
