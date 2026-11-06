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
    @State private var rejectingCookies = true
    @State private var cookieReason: ConsentHandler.Reason?
    @State private var siteSettingsOpen = false
    @State private var darkPages = true
    /// Shown only on a page that publishes a recipe.
    @State private var hasRecipe = false
    /// What the page's words are in, once read: there's no translating into that.
    @State private var pageLanguage: String?

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
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 14) {
                        addressRow(tab)
                        actionTiles(tab)
                        pageGroup(tab)
                        blockingCard(tab)
                        siteGroup(tab).id(Self.siteSettings)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                // Opened at the foot of the sheet, its rows would arrive out of sight. Once they've
                // opened: until then the list can't scroll past the height it had.
                .onChange(of: siteSettingsOpen) { _, open in
                    guard open else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                        guard siteSettingsOpen else { return }
                        withAnimation(.snappy(duration: 0.25)) { scroller.scrollTo(Self.siteSettings, anchor: .top) }
                    }
                }
            }
            // From inside the list too, not only by the grabber: pulled down at its top, the menu closes.
            .pullsDownToClose(distance: 60) { browser.panel = .none }
            .scrollBounceBehavior(.always)
            .task(id: tab.url) {
                guard let webView = tab.webView else { return }
                pageLanguage = await PageTranslator.shared.language(of: webView)
                hasRecipe = await RecipeReader.read(webView) != nil
            }
            // Scrolled rows slip away a little under the grabber, not into it.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 6)
                    Color.black
                    // And dissolve at the foot, where the sheet ends mid-row.
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                }
            }
            .padding(.top, 14)
            .foregroundStyle(Theme.ink)
            .onAppear {
                let host = tab.url?.host()
                blockingOn = !(host.map { ContentBlocker.shared.isAllowed(host: $0) } ?? false)
                popupsOn = !(host.map { ContentBlocker.shared.isAllowed(host: $0, category: .popups) } ?? false)
                cookieReason = host.flatMap(ConsentHandler.shared.acceptance)
                darkPages = !(host.map(ForceDark.isLeftOut) ?? false)
                rejectingCookies = cookieReason == nil
            }
        }
    }

    private static let siteSettings = "siteSettings"

    // MARK: Address

    private func addressRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 0) {
            iconButton(.back, "Back") {
                if tab.canGoBack {
                    tab.webView?.goBack()
                    browser.panel = .none
                } else {
                    browser.returnToSaved(from: tab)
                }
            }
            .disabled(!tab.canGoBack && tab.savedPlace == nil)
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
                // Without the parts that only say where it came from.
                let link = tab.url.map(CleanLink.clean)
                UIPasteboard.general.url = link
                if let link { CopiedLink.copiedHere(link) }
                browser.panel = .none
                browser.showToast("Link copied")
            }
            if tab.isLoading {
                iconButton(.close, "Stop loading") { tab.webView?.stopLoading(); browser.panel = .none }
            } else {
                iconButton(.reload, "Reload") { tab.webView?.reload(); browser.panel = .none }
            }
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
                ShareLink(item: CleanLink.clean(url)) {
                    ActionTile.Face(glyph: .share, title: "Share")
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: Page

    private func pageGroup(_ tab: BrowserTab) -> some View {
        VStack(spacing: 0) {
            ToolRow(glyph: .reader, title: "Reader Mode") { browser.openReader() }

            if hasRecipe {
                ToolRow(glyph: .cook, title: "Cook Mode") { browser.cookThisPage() }
            }

            // Not for private tabs: following keeps the site's address.
            if !tab.isPrivate, tab.url?.displayHost != nil {
                ToolRow(glyph: .news, title: "Follow in News", detail: browser.followsThisPage ? "Following" : "") {
                    browser.followsThisPage ? (browser.panel = .feed) : browser.followPage()
                }
            }

            // Not for private tabs: the list keeps the page and its text.
            if !tab.isPrivate {
                ToolRow(glyph: .readLater, title: "Save for Later", detail: ReadLater.shared.contains(tab.url) ? "Saved" : "") {
                    ReadLater.shared.contains(tab.url) ? (browser.panel = .readLater) : browser.saveForLater()
                }
            }

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
                        .disabled(PageZoom.isAtLimit(tab.zoomLevel, direction: -1))
                    // Tapped: back to the page's own size.
                    Button { tab.resetZoom() } label: {
                        Text("\(Int((tab.zoomLevel * 100).rounded()))%")
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .frame(width: 50, height: 38)
                            .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                    .disabled(tab.zoomLevel == 1)
                    .accessibilityLabel("Page zoom \(Int((tab.zoomLevel * 100).rounded())) percent")
                    .accessibilityHint(tab.zoomLevel == 1 ? "" : "Back to 100 percent")
                    zoomButton("+", "Zoom in") { tab.stepZoom(1) }
                        .disabled(PageZoom.isAtLimit(tab.zoomLevel, direction: 1))
                }
                .background(Theme.panel, in: .capsule)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ToolRow(glyph: .split, title: browser.split == nil ? "Split View" : "Close Split View") {
                // Starting it opens the bar for the second page; it closes this menu itself.
                if browser.split == nil { browser.startSplit() } else { browser.endSplit(); browser.panel = .none }
            }

            ToolRow(glyph: .pdf, title: "Save as PDF") {
                browser.panel = .none
                guard let webView = tab.webView else { return }
                Task {
                    let saved = await PagePDF.save(webView, title: tab.displayTitle)
                    if !saved { browser.showToast("Couldn't save this page") }
                }
            }

            // Only while something is coming in; otherwise the bar finds it.
            if Downloads.shared.activeCount > 0 {
                ToolRow(glyph: .download, title: "Downloads", detail: downloadsDetail) { browser.panel = .downloads }
            }
        }
        .padding(.vertical, 4)
        .background(Theme.raised, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.edge))
    }

    /// Tap the row: translate into the language used last, or back to the original.
    /// With more than one to choose from, the capsule lists them. A language the page
    /// is already in isn't offered.
    @ViewBuilder
    private func translateRow(_ tab: BrowserTab) -> some View {
        // The one it's translated into stays listed: read now, the page says it's in that.
        let choices = TranslationTarget.allCases.filter { $0 == tab.translation || $0.language != pageLanguage }
        let isOn = tab.translation != nil
        if let shown = tab.translation ?? choices.first {
            HStack(spacing: 14) {
                Button {
                    if isOn {
                        Task { await tab.translate(to: nil) }
                        browser.panel = .none
                        browser.showToast("Showing the original")
                    } else {
                        translate(tab, to: shown)
                    }
                } label: {
                    HStack(spacing: 14) {
                        Glyph(.translate).foregroundStyle(Theme.secondaryInk).frame(width: 24)
                        Text(isOn ? "Show Original" : "Translate").font(.system(size: 16)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        if choices.count < 2 {
                            Text(shown.name)
                                .font(.system(size: 13))
                                .foregroundStyle(isOn ? Theme.accentText : Theme.faintInk)
                        }
                    }
                    .padding(.vertical, 12)
                    // As tall as Page Zoom's row while the capsule's beside it.
                    .frame(minHeight: choices.count > 1 ? 54 : nil)
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel(isOn ? "Show original" : "Translate to \(shown.name)")
                if choices.count > 1 {
                    Menu {
                        ForEach(choices) { target in
                            Button(target.name) { translate(tab, to: target) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(shown.name)
                                .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? Theme.accentText : Theme.ink)
                            Glyph(.chevronUp, size: 10, weight: 2)
                                .rotationEffect(.degrees(180))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Theme.panel, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .menuIndicator(.hidden)
                    .menuOrder(.fixed)
                    .accessibilityLabel("Language, \(shown.name)")
                }
            }
            .padding(.horizontal, 16)
        } else {
            // Every language chosen in Settings is the one this page is in.
            HStack(spacing: 14) {
                Glyph(.translate).foregroundStyle(Theme.faintInk).frame(width: 24)
                Text("Translate").font(.system(size: 16)).foregroundStyle(Theme.faintInk)
                Spacer(minLength: 0)
                Text("Already in \(TranslationTarget.allCases.first?.name ?? "your language")")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faintInk)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private func translate(_ tab: BrowserTab, to target: TranslationTarget) {
        TranslationTarget.used(target)
        browser.panel = .none
        browser.showToast("Translating to \(target.name)")
        Task {
            switch await tab.translate(to: target) {
            case .translated: browser.showToast("Translated to \(target.name)")
            case .partly: browser.showToast("Translated part of this page")
            case .empty: browser.showToast("Nothing to translate here")
            case .failed: browser.showToast("Couldn't translate this page")
            }
        }
    }

    private var downloadsDetail: String {
        let active = Downloads.shared.activeCount
        return active > 0 ? "\(active) downloading" : "\(Downloads.shared.items.count)"
    }

    private func hiddenDetail(_ tab: BrowserTab) -> String {
        let count = tab.url?.host().map { HiddenItems.shared.selectors(for: $0).count } ?? 0
        return count == 0 ? "" : "\(count) hidden"
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

    /// The way out when blocking breaks a site, as in Arc. WebKit doesn't say
    /// how much it blocked, so this says what, not how many.
    private func blockingCard(_ tab: BrowserTab) -> some View {
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
                // Blocking off for the site, or a kind of it off in Settings: these do nothing
                // here, and say so, rather than stay on and describe what isn't happening.
                let popupsHeld = heldBack(by: .popups)
                let cookiesHeld = heldBack(by: .cookies)
                toggleRow(glyph: .popup, title: "Block pop-ups",
                          detail: popupsHeld ?? (popupsOn ? "Newsletter and promo overlays hidden" : "Allowed on this site"), isOn: Binding(
                    get: { popupsHeld == nil && popupsOn },
                    set: { on in
                        popupsOn = on
                        ContentBlocker.shared.setAllowed(host: host, category: .popups, !on)
                        tab.webView?.reload()
                    }))
                    .disabled(popupsHeld != nil)
                toggleRow(glyph: .cookie, title: "Reject cookies", detail: cookiesHeld ?? cookieDetail, isOn: Binding(
                    get: { cookiesHeld == nil && rejectingCookies },
                    set: { on in
                        rejectingCookies = on
                        ConsentHandler.shared.setAccepted(on ? nil : .chosen, for: host)
                        cookieReason = on ? nil : .chosen
                    }))
                    .disabled(cookiesHeld != nil)
                if ForceDark.isOn {
                    toggleRow(glyph: .forceDark, title: "Force dark",
                              detail: darkPages ? "This site is dark" : "Off on this site", isOn: Binding(
                        get: { darkPages },
                        set: { on in
                            darkPages = on
                            ForceDark.leaveOut(host, !on)
                            tab.webView?.reload()
                        }))
                }
                ToolRow(glyph: .hideItems, title: "Hide Distracting Items", detail: hiddenDetail(tab)) {
                    browser.startHidingItems()
                }
                if !HiddenItems.shared.selectors(for: host).isEmpty {
                    ToolRow(glyph: .hideItems, title: "Show Hidden Items") { browser.showHiddenItems() }
                }
                ToolRow(glyph: .desktop, title: tab.wantsDesktopSite ? "Request Mobile Site" : "Request Desktop Site") {
                    tab.setDesktopSite(!tab.wantsDesktopSite)
                    browser.panel = .none
                }
                ToolRow(glyph: .settings, title: "All settings") { browser.panel = .settings }
            }
        }
        .padding(.vertical, 2)
        .background(Theme.raised, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.edge))
    }

    /// Why a kind of blocking isn't running on this site, if something above it has it off.
    private func heldBack(by category: ContentBlocker.Category) -> String? {
        if !blockingOn { return "Off with blocking" }
        return ContentBlocker.shared.isEnabled(category) ? nil : "Off in Settings"
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
            .padding(.vertical, 12)
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
