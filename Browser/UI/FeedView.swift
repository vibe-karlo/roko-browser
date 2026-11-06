import SwiftUI

/// News and Saved, the two halves of what there is to read. Plain words, the
/// one you're on in ink: switching doesn't animate, it's the same screen.
struct ReadingSwitch: View {
    @Environment(BrowserModel.self) private var browser
    let current: BrowserModel.Panel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            word("News", panel: .feed)
            word("Saved", panel: .readLater)
        }
    }

    private func word(_ title: String, panel: BrowserModel.Panel) -> some View {
        Button {
            guard panel != current else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { browser.panel = panel }
        } label: {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(panel == current ? Theme.ink : Theme.faintInk)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(panel == current ? .isSelected : [])
    }
}

/// What you follow, each event once, ending when you've seen it: stories
/// several sites covered gathered under one line, which opens a comparison of
/// them; the rest one by one, which open in Reader. Swipe right to mark read,
/// left to save. Pull down past the top to close.
struct FeedView: View {
    @Environment(BrowserModel.self) private var browser
    private var store: FeedStore { .shared }
    @State private var showsSources = false
    @State private var showsRead = false
    /// Lists showing in full.
    @State private var openLists = Set<String>()
    /// A site's list, before "more".
    private static let listLength = 4

    var body: some View {
        List {
            header.plainRow(top: 26, bottom: 22)
            if !store.followsAnything {
                Text("Nothing followed yet. Choose a few sites, or follow one from its page's tools.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryInk)
                    .plainRow(top: 8, bottom: 0)
            } else if store.blocks.isEmpty, store.readItems.isEmpty {
                StatusLine(text: store.isRefreshing ? "Reading what you follow" : "Nothing new in the last two days")
                    .plainRow(top: 8, bottom: 0)
            }
            ForEach(store.blocks) { block in blockView(block) }
            if !store.blocks.isEmpty || !store.readItems.isEmpty {
                ending.plainRow(top: 10, bottom: 20)
            }
            if showsRead {
                ForEach(store.readItems) { item in row(item).plainRow(top: 0, bottom: 22) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // A reading column on a Duo lying open: a lead picture across all of it wouldn't fit the screen.
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.3), value: store.blocks)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ContextBar(leading: .init(glyph: .close, label: "Close", action: close),
                       glyph: .news, title: "Sources",
                       launch: { showsSources = true }, morphs: false)
                .padding(.top, 10)
                // Stories end at the bar: none carries on below it.
                .background(Theme.canvas)
                .background(alignment: .top) { FadeEdge(color: Theme.canvas) }
        }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .task { await store.opened() }
        .onScrollPhaseChange { _, phase in
            if phase != .idle { store.noteReading() }
        }
        .sheet(isPresented: $showsSources) {
            NewsSitesSheet(showsNewsletters: true) { Task { await store.refresh(immediately: true) } }
                .presentationBackground(Theme.panel)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulled in
            if pulled { close() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReadingSwitch(current: .feed)
            if store.followsAnything {
                Button {
                    if store.hasNewer {
                        withAnimation(.snappy(duration: 0.3)) { store.showNewer() }
                    } else {
                        Task { await store.refresh(immediately: true) }
                    }
                } label: {
                    Text(status)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk)
                        .monospacedDigit()
                        .frame(minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityHint("Looks for new stories")
            }
        }
    }

    private var status: String {
        if store.hasNewer { return "New stories, show them" }
        if store.isRefreshing { return "Looking…" }
        let count = store.unreadCount
        let left = count == 1 ? "1 to read" : "\(count) to read"
        guard let refreshed = store.refreshedAt else { return left }
        return left + ", updated " + refreshed.formatted(.relative(presentation: .named))
    }

    /// Where the feed stops: nothing below this is new.
    private var ending: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.unreadCount == 0 ? "All read" : "That's everything")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            Spacer(minLength: 12)
            if !store.readItems.isEmpty {
                Button { withAnimation(.snappy(duration: 0.3)) { showsRead.toggle() } } label: {
                    Text(showsRead ? "Hide read" : "Show \(store.readItems.count) read")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: FeedBlock) -> some View {
        switch block {
        case .lead(let item):
            lead(item).plainRow(top: 2, bottom: 26)
        case .row(let item):
            row(item).plainRow(top: 0, bottom: 22)
        case .pair(let first, let second):
            HStack(alignment: .top, spacing: 14) {
                tile(first)
                tile(second)
            }
            .plainRow(top: 2, bottom: 26)
        case .site(let host, let stories):
            lines(stories, key: block.id, showsSite: false) {
                HStack(spacing: 8) {
                    SiteIcon(host: host, size: 18, remote: true)
                    Text(host)
                }
            }
        case .brief(let stories):
            lines(stories, key: block.id, showsSite: true) { Text("Briefly") }
        case .mail(let stories):
            lines(stories, key: block.id, showsSite: true) { Text("Newsletters") }
        }
    }

    /// Across the page: the picture, then the headline large.
    private func lead(_ item: FeedItem) -> some View {
        let stories = item.stories
        let read = stories.allSatisfy(\.isRead)
        return Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 12) {
                if let first = stories.first(where: { $0.story.image != nil }) {
                    Theme.raised
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .overlay { FeedPicture(story: first.story, isLarge: true) }
                        .clipShape(.rect(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.edge))
                        .opacity(read ? 0.6 : 1)
                }
                Text(title(of: item))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(read ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                sources(item)
            }
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .storyMenu { menu(item) }
        .feedSwipes(item, store: store, browser: browser)
        .onAppear { store.wantCheck(item.stories) }
        .onDisappear { store.dropCheck(item.stories) }
    }

    /// Half the page. Headlines hold three lines' room, so the pair's end level.
    private func tile(_ item: FeedStory) -> some View {
        Button { browser.read(item.story) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Theme.raised
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { FeedPicture(story: item.story) }
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.edge))
                    .opacity(item.isRead ? 0.6 : 1)
                Text(item.story.title)
                    .font(.system(size: 15, weight: item.isRead ? .regular : .medium))
                    .foregroundStyle(item.isRead ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                // Half a page's width has no room for the site's name.
                HStack(spacing: 6) {
                    SiteIcon(host: item.story.host, size: 13, remote: true)
                    Text(ago(item.when))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faintInk)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.story.host + ", " + ago(item.when))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        // Two buttons in one list row: without this a tap would press both.
        .buttonStyle(.plain)
        .storyMenu { menu(.story(item)) }
    }

    /// Held down: what a swipe does, and the wish to see less of it.
    @ViewBuilder
    private func menu(_ item: FeedItem) -> some View {
        let read = item.stories.allSatisfy(\.isRead)
        let links = item.stories.map(\.id)
        Button(read ? "Mark Unread" : "Mark Read") {
            read ? store.markUnread(links) : store.markRead(links)
        }
        if case .story(let story) = item, !story.story.isMail {
            Button("Save to Read Later") { save(story) }
        }
        // A newsletter has its own way out: Unsubscribe.
        if !item.stories.contains(where: \.story.isMail) {
            Button("Show Less News Like This") {
                Task {
                    await store.showLess(item.stories.map(\.story))
                    browser.showToast("Showing less like this")
                }
            }
            // One site, or for an event, which of them.
            let hosts = Array(Set(item.stories.map(\.story.host))).sorted()
            if hosts.count == 1 {
                Button("Don't Show \(hosts[0])") { dontShow(hosts[0]) }
            } else {
                Menu("Don't Show a Site") {
                    ForEach(hosts, id: \.self) { host in
                        Button(host) { dontShow(host) }
                    }
                }
            }
        }
    }

    private func dontShow(_ host: String) {
        Task {
            await store.dontShow(host: host)
            browser.showToast("News won't show \(host)")
        }
    }

    /// One thing, with its picture beside it, or its fanned pictures for an event.
    private func row(_ item: FeedItem) -> some View {
        let read = item.stories.allSatisfy(\.isRead)
        return Button { open(item) } label: {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if case .story(let story) = item {
                        FeedPicture(story: story.story)
                            .frame(width: 68, height: 68)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.edge))
                    } else {
                        // Only real pictures fanned: an empty card behind says nothing.
                        let pictured = item.stories.filter { $0.story.image != nil }
                        FeedPile(stories: Array((pictured.isEmpty ? item.stories : pictured).prefix(3)))
                    }
                }
                .opacity(read ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(of: item))
                        .font(.system(size: 16, weight: read ? .regular : .medium))
                        .foregroundStyle(read ? Theme.secondaryInk : Theme.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    sources(item)
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .storyMenu { menu(item) }
        .feedSwipes(item, store: store, browser: browser)
        .onAppear { store.wantCheck(item.stories) }
        .onDisappear { store.dropCheck(item.stories) }
    }

    /// Stories as lines, under a heading, in a panel of their own: a few, and the rest a tap away.
    @ViewBuilder
    private func lines(_ stories: [FeedStory], key: String, showsSite: Bool, @ViewBuilder heading: () -> some View) -> some View {
        let shown = openLists.contains(key) ? stories : Array(stories.prefix(Self.listLength))
        let hidden = stories.count - shown.count
        listHeading(heading)
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, story in
            line(story, showsSite: showsSite)
                .panelRow(.init(isFirst: false, isLast: hidden == 0 && index == shown.count - 1))
        }
        if hidden > 0 {
            Button { withAnimation(.snappy(duration: 0.3)) { _ = openLists.insert(key) } } label: {
                Text("\(hidden) more")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .panelRow(.init(isFirst: false, isLast: true))
        }
    }

    private func listHeading(@ViewBuilder _ title: () -> some View) -> some View {
        title()
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelRow(.init(isFirst: true, isLast: false))
            .accessibilityAddTraits(.isHeader)
    }

    /// A story as a line of a list: no picture.
    private func line(_ item: FeedStory, showsSite: Bool) -> some View {
        Button { browser.read(item.story) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.story.title)
                    .font(.system(size: 15, weight: item.isRead ? .regular : .medium))
                    .foregroundStyle(item.isRead ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if showsSite { SiteIcon(host: item.story.host, size: 13, remote: true) }
                    Text((showsSite ? (item.story.from ?? item.story.host) + " · " : "") + ago(item.when))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faintInk)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .storyMenu { menu(.story(item)) }
        .feedSwipes(.story(item), store: store, browser: browser)
    }

    /// Who has it: a site and when, or for an event, every site.
    @ViewBuilder
    private func sources(_ item: FeedItem) -> some View {
        switch item {
        case .story(let story):
            HStack(spacing: 6) {
                SiteIcon(host: story.story.host, size: 13, remote: true)
                Text(story.story.host + " · " + ago(story.when))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faintInk)
                    .lineLimit(1)
            }
        case .group(let stories):
            let hosts = Array(NSOrderedSet(array: stories.map(\.story.host))) as? [String] ?? []
            HStack(spacing: 5) {
                ForEach(hosts.prefix(5), id: \.self) { host in
                    SiteIcon(host: host, size: 14, remote: true)
                }
                Text("\(hosts.count) sites")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faintInk)
                    .padding(.leading, 3)
                    .lineLimit(1)
            }
        }
    }

    private func title(of item: FeedItem) -> String {
        StoryGroups.title(of: item.stories.map(\.story))
    }

    private func ago(_ date: Date) -> String {
        // A site's clock can run ahead: germanijak.hr dates in local time, marked as UTC.
        date.timeIntervalSinceNow > -60 ? "now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private func open(_ item: FeedItem) {
        switch item {
        case .story(let story): browser.read(story.story)
        case .group(let stories): browser.compare(stories.map(\.story))
        }
    }

    private func save(_ item: FeedStory) {
        ReadLater.shared.save(item.story, text: store.keptText(of: item.id) ?? "")
        browser.showToast("Saved to Read Later")
    }

    private func close() {
        browser.panel = .none
    }
}

/// Three pictures at most, fanned a few degrees apart, the first on top.
private struct FeedPile: View {
    let stories: [FeedStory]
    private static let angles: [Double] = [0, -9, 8]

    var body: some View {
        ZStack {
            ForEach(Array(stories.enumerated().reversed()), id: \.element.id) { index, item in
                FeedPicture(story: item.story)
                    .frame(width: 52, height: 68)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.edge))
                    .rotationEffect(.degrees(Self.angles[index]), anchor: .bottom)
                    .offset(x: CGFloat(index) * 4, y: CGFloat(index) * -2)
            }
        }
        // As wide as a single story's picture, so every headline starts on one line.
        .frame(width: 68, height: 76)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A story's long-press menu. Held up, the story has room around it in its
    /// rounded shape, its text clear of the edge; on the page it stays where it was.
    func storyMenu(@ViewBuilder _ menu: () -> some View) -> some View {
        padding(8)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 16, style: .continuous))
            .contextMenu { menu() }
            .padding(-8)
    }
}

private extension View {
    /// Swipe right to mark read, and left, for one story, to save it.
    func feedSwipes(_ item: FeedItem, store: FeedStore, browser: BrowserModel) -> some View {
        let links = item.stories.map(\.id)
        let read = item.stories.allSatisfy(\.isRead)
        return swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                read ? store.markUnread(links) : store.markRead(links)
            } label: { Text(read ? "Unread" : "Read") }
                .tint(Theme.faintInk)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if case .story(let story) = item, !story.story.isMail {
                Button {
                    ReadLater.shared.save(story.story, text: store.keptText(of: story.id) ?? "")
                    browser.showToast("Saved to Read Later")
                } label: { Text("Save") }
                    .tint(Theme.faintInk)
            }
        }
    }

    /// A row of a list set in a panel of its own, rounded only at the panel's
    /// ends, with the gutter around it the page's text has.
    func panelRow(_ place: PanelPlace) -> some View {
        listRowInsets(EdgeInsets(top: place.isFirst ? 16 : 7, leading: 34, bottom: place.isLast ? 26 : 7, trailing: 34))
            .listRowSeparator(.hidden)
            .listRowBackground(
                UnevenRoundedRectangle(topLeadingRadius: place.isFirst ? 18 : 0, bottomLeadingRadius: place.isLast ? 18 : 0,
                                       bottomTrailingRadius: place.isLast ? 18 : 0, topTrailingRadius: place.isFirst ? 18 : 0,
                                       style: .continuous)
                    .fill(Theme.panel)
                    .padding(.horizontal, 16)
                    // Clear of the next block, only below the panel's end.
                    .padding(.bottom, place.isLast ? 10 : 0)
            )
    }
}

private struct PanelPlace {
    let isFirst: Bool
    let isLast: Bool
}

/// A story's picture from its feed; the site's icon on the panel colour
/// without one. Large, the article's own picture takes over once it's found:
/// feeds carry thumbnails, soft at the width of the page.
struct FeedPicture: View {
    let story: NewsStory
    var isLarge = false
    @State private var large: URL?

    var body: some View {
        ZStack {
            Theme.raised
            SiteIcon(host: story.host, size: 22, remote: true)
            if let image = story.image { picture(image) }
            if let large { picture(large) }
        }
        .clipped()
        .task(id: story.link) {
            if isLarge { large = await FeedStore.shared.largePicture(of: story.link) }
        }
    }

    private func picture(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if let picture = phase.image { picture.resizable().scaledToFill() }
        }
    }
}
