import SwiftData
import SwiftUI

/// Everything about the current page, one tap from ⌃: where you are (address,
/// copy, reload), the four things you do most, how the page looks, and how this
/// site is treated by the blocker.
struct ToolsSheet: View {
    @Environment(BrowserModel.self) private var browser
    @Query private var watches: [Watch]
    @State private var blockingOn = true
    @State private var popupsOn = true
    @State private var pinchOn = true
    @State private var rejectingCookies = true
    @State private var cookieReason: ConsentHandler.Reason?
    @State private var siteSettingsOpen = false

    /// What happens to this site's cookie pop-ups, and why.
    private var cookieDetail: String {
        switch cookieReason {
        case nil: "Pop-ups answered with reject"
        case .wall, .content: "Accepted: the site needs them"
        case .chosen: "Accepted on this site"
        }
    }

    var body: some View {
        if let tab = browser.selectedTab {
            ScrollView {
                VStack(spacing: 14) {
                    addressRow(tab)
                    actionTiles(tab)
                    pageGroup(tab)
                    siteGroup(tab)
                    blockingFooter(tab)
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .foregroundStyle(Theme.ink)
            .onAppear {
                let host = tab.url?.host()
                blockingOn = !(host.map { ContentBlocker.shared.isAllowed(host: $0) } ?? false)
                popupsOn = !(host.map { ContentBlocker.shared.isAllowed(host: $0, category: .popups) } ?? false)
                pinchOn = PinchToSummarize.isOn(for: host)
                cookieReason = host.flatMap(ConsentHandler.shared.acceptance)
                rejectingCookies = cookieReason == nil
            }
        }
    }

    // MARK: Address

    private func addressRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 0) {
            iconButton(.back, "Back") { tab.webView?.goBack(); browser.panel = .none }
                .disabled(!tab.canGoBack)
            iconButton(.forward, "Forward") { tab.webView?.goForward(); browser.panel = .none }
                .disabled(!tab.canGoForward)

            Button {
                browser.showCommandBar(prefill: tab.url?.absoluteString ?? "", mode: .currentTab)
            } label: {
                VStack(spacing: 1) {
                    Text(tab.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(tab.url?.displayHost ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit the address")

            iconButton(.link, "Copy link") {
                UIPasteboard.general.url = tab.url
                if let url = tab.url { CopiedLink.copiedHere(url) }
                browser.panel = .none
                browser.showToast("Link copied")
            }
            iconButton(.reload, "Reload") { tab.webView?.reload(); browser.panel = .none }
        }
        .padding(.horizontal, 6)
        .frame(height: 60)
        .background(Theme.raised, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.edge))
    }

    private func iconButton(_ glyph: Glyph.Kind, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: 20)
                .frame(width: 44, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func actionTiles(_ tab: BrowserTab) -> some View {
        HStack(spacing: 10) {
            ActionTile(glyph: .search, title: "Find on Page") {
                browser.panel = .none
                tab.webView?.findInteraction?.presentFindNavigator(showingReplace: false)
            }
            ActionTile(glyph: .summarize, title: "Summarize") { browser.summarize() }
            ActionTile(glyph: .pin, title: browser.isPinned(tab.url) ? "Unpin" : "Pin") {
                browser.togglePin(for: tab)
                browser.panel = .none
                browser.showToast(browser.isPinned(tab.url) ? "Pinned" : "Unpinned")
            }
            if let url = tab.url {
                ShareLink(item: url) { ActionTile.Face(glyph: .share, title: "Share") }
                    .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: Page

    private func pageGroup(_ tab: BrowserTab) -> some View {
        VStack(spacing: 0) {
            ToolRow(glyph: .reader, title: "Reader Mode") { browser.openReader() }

            // Not for private tabs: watching keeps the page's address.
            if !tab.isPrivate {
                ToolRow(glyph: .bell, title: "Notify Me", detail: isWatched(tab) ? "On" : "") { browser.panel = .notifyMe }
            }

            translateRow(tab)

            HStack(spacing: 14) {
                Glyph(.textSize).foregroundStyle(Theme.secondaryInk).frame(width: 24)
                Text("Page Zoom").font(.system(size: 16))
                Spacer()
                HStack(spacing: 0) {
                    zoomButton("−", "Zoom out") { tab.stepZoom(-1) }
                    Text("\(Int((tab.zoomLevel * 100).rounded()))%")
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .frame(width: 50)
                    zoomButton("+", "Zoom in") { tab.stepZoom(1) }
                }
                .background(Theme.panel, in: .capsule)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ToolRow(glyph: .desktop, title: tab.wantsDesktopSite ? "Request Mobile Site" : "Request Desktop Site") {
                tab.setDesktopSite(!tab.wantsDesktopSite)
                browser.panel = .none
            }
        }
        .padding(.vertical, 4)
        .background(Theme.raised, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.edge))
    }

    /// Translate into English or Croatian; the language in use is lit, and
    /// tapping it again brings back the original.
    private func translateRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 14) {
            Glyph(.translate).foregroundStyle(Theme.secondaryInk).frame(width: 24)
            Text(tab.translation == nil ? "Translate" : "Translated").font(.system(size: 16))
            Spacer()
            HStack(spacing: 0) {
                ForEach(TranslationTarget.allCases) { target in
                    let isOn = tab.translation == target
                    Button {
                        tab.translate(to: isOn ? nil : target)
                        browser.panel = .none
                        browser.showToast(isOn ? "Showing the original" : "Translating to \(target.name)")
                    } label: {
                        Text(target.name)
                            .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? Theme.accent : Theme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel(isOn ? "Show original" : "Translate to \(target.name)")
                }
            }
            .background(Theme.panel, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func isWatched(_ tab: BrowserTab) -> Bool {
        guard let url = tab.url?.absoluteString else { return false }
        return watches.contains { $0.url == url }
    }

    private func zoomButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 38)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Site

    private func siteGroup(_ tab: BrowserTab) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { siteSettingsOpen.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Glyph(.settings).foregroundStyle(Theme.secondaryInk).frame(width: 24)
                    Text("Site Settings").font(.system(size: 16))
                    Spacer()
                    Glyph(.chevronUp, size: 16)
                        .foregroundStyle(Theme.secondaryInk)
                        .rotationEffect(.degrees(siteSettingsOpen ? 0 : 180))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())

            if siteSettingsOpen, let host = tab.url?.host() {
                toggleRow(glyph: .blocking, title: "Block ads and trackers",
                          detail: URL(string: "https://\(host)")?.displayHost ?? host, isOn: Binding(
                    get: { blockingOn },
                    set: { on in
                        blockingOn = on
                        ContentBlocker.shared.setAllowed(host: host, !on)
                        tab.webView?.reload()
                    }))
                toggleRow(glyph: .popup, title: "Block pop-ups",
                          detail: popupsOn ? "Newsletter and promo overlays hidden" : "Allowed on this site", isOn: Binding(
                    get: { popupsOn },
                    set: { on in
                        popupsOn = on
                        ContentBlocker.shared.setAllowed(host: host, category: .popups, !on)
                        tab.webView?.reload()
                    }))
                    .disabled(!blockingOn || !ContentBlocker.shared.isEnabled(.popups))
                toggleRow(glyph: .cookie, title: "Reject cookies", detail: cookieDetail, isOn: Binding(
                    get: { rejectingCookies },
                    set: { on in
                        rejectingCookies = on
                        ConsentHandler.shared.setAccepted(on ? nil : .chosen, for: host)
                        cookieReason = on ? nil : .chosen
                    }))
                    .disabled(!blockingOn || !ContentBlocker.shared.isEnabled(.cookies))
                toggleRow(glyph: .summarize, title: "Pinch to summarize",
                          detail: pinchOn ? "Pinching in summarizes" : "Pinching zooms instead", isOn: Binding(
                    get: { pinchOn },
                    set: { on in
                        pinchOn = on
                        PinchToSummarize.set(on, for: host)
                    }))
                ToolRow(glyph: .settings, title: "All settings") { browser.panel = .settings }
            }
        }
        .padding(.vertical, 2)
        .background(Theme.raised, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.edge))
    }

    private func toggleRow(glyph: Glyph.Kind, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Glyph(glyph).foregroundStyle(Theme.secondaryInk).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16))
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Footer

    /// The escape hatch when blocking breaks a site, as in Arc.
    private func blockingFooter(_ tab: BrowserTab) -> some View {
        Button {
            guard let host = tab.url?.host() else { return }
            let restore = blockingOn
            blockingOn = !restore
            ContentBlocker.shared.setAllowed(host: host, restore)
            tab.webView?.reload()
            browser.panel = .none
            browser.showToast(restore ? "Showing the original page" : "Blocking again")
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(blockingOn ? "Ads, trackers and pop-ups blocked" : "Blocking is off for this site")
                    .font(.system(size: 15, weight: .medium))
                Text(blockingOn ? "Problems? Tap to restore the original page" : "Tap to block again")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.raised, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.edge))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One of the four big actions: the glyph on a raised square, its name below.
private struct ActionTile: View {
    let glyph: Glyph.Kind
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(glyph: glyph, title: title) }
            .buttonStyle(RowButtonStyle())
    }

    struct Face: View {
        let glyph: Glyph.Kind
        let title: String

        var body: some View {
            VStack(spacing: 8) {
                Glyph(glyph, size: 24)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                    .background(Theme.raised, in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.edge))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
    }
}

private struct ToolRow: View {
    let glyph: Glyph.Kind
    let title: String
    var detail: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Glyph(glyph).foregroundStyle(Theme.secondaryInk).frame(width: 24)
                Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
                Spacer()
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.faintInk)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
