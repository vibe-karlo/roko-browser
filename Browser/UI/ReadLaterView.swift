import SwiftUI

/// The pages put aside, gathered by why they were saved or by when, whichever
/// was last chosen here. What's been opened stays in its group, after what hasn't
/// and marked, so a page kept to come back to can still be found where it belongs.
/// A summary of a group's unread pages is a tap away. More than a column's worth
/// makes a shelf that swipes sideways, so one full group can't bury the others.
/// Search looks through all of it. Tap a page to read it (it counts as read);
/// touch and hold to remove it or mark it read or not, or outside a shelf, swipe.
/// The bar's middle searches; its right writes one summary across everything unread.
/// Pull down past the top to close.
struct ReadLaterView: View {
    @Environment(BrowserModel.self) private var browser
    private var store: ReadLater { .shared }

    private var unread: [ReadLaterPage] { store.unread }
    @AppStorage(SavedGrouping.key) private var grouping: SavedGrouping = .topic
    @Namespace private var switchSpace
    /// Left at the top by the reader, not by the list moving under them.
    @State private var isAtTop = true
    /// The page just come back from, for its shelf to show it.
    @State private var returningTo: UUID?
    @State private var isSearching = false
    @State private var query = ""
    /// What the search found, and what for: nothing found isn't said until it has looked.
    @State private var found: [UUID] = []
    @State private var searchedFor = ""
    @FocusState private var isTyping: Bool
    /// A shelf's column, as many pages as fit a look.
    private static let columnLength = 4

    private var words: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sections: [SavedSection] {
        switch grouping {
        case .topic: SavedSection.byTopic(store.pages, sorting: store.isSorting)
        case .date: SavedSection.byDate(store.pages)
        }
    }

    var body: some View {
        ScrollViewReader { scroller in
            list(scroller)
                .onAppear { takeUpWhereLeft(scroller) }
                // A list keeps the rows on screen in place as others move, so pages being
                // sorted, or the other grouping, would carry someone at the top down the page.
                .onChange(of: sections.map { "\($0.id) \($0.pages.count)" }) {
                    if isAtTop { scroller.scrollTo("top", anchor: .top) }
                }
        }
    }

    /// Back from a page opened here: the search it was found by, or its group, and on
    /// a shelf the column it's in (it may have moved along, now that it's read).
    private func takeUpWhereLeft(_ scroller: ScrollViewProxy) {
        guard let place = browser.savedPlaceToRestore else { return }
        browser.savedPlaceToRestore = nil
        if !place.query.isEmpty {
            isSearching = true
            query = place.query
        }
        guard place.query.isEmpty, let section = sections.first(where: { $0.pages.contains { $0.id == place.page } }) else { return }
        isAtTop = false
        returningTo = place.page
        scroller.scrollTo(section.id, anchor: .top)
        Task {
            try? await Task.sleep(for: .seconds(1))
            returningTo = nil
        }
    }

    private func list(_ scroller: ScrollViewProxy) -> some View {
        List {
            header
                .id("top")
                .plainRow(top: 26, bottom: store.pages.isEmpty ? 8 : 22)
            if store.pages.isEmpty {
                Text("Nothing saved yet. Save a page from its tools, or type \u{201C}read later\u{201D} on it.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryInk)
                    .plainRow(top: 30, bottom: 0)
            }
            if store.pages.count >= 2 || isSearching {
                tools.plainRow(top: 0, bottom: 18)
            }
            if isSearching, !words.isEmpty {
                results
            } else {
                // One page is nothing to gather.
                if store.pages.count >= 2 {
                    ForEach(sections) { section in
                        heading(section).id(section.id).plainRow(top: 8, bottom: 12)
                        rows(section.pages)
                    }
                } else {
                    rows(store.pages)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .animation(.snappy(duration: 0.3), value: store.pages)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Above the keyboard it would only sit on the results.
            if !isTyping {
                ContextBar(leading: .init(glyph: .close, label: "Close", action: close),
                           glyph: .search, title: "Search",
                           launch: { search(scroller) },
                           trailing: unread.isEmpty ? nil : .init(glyph: .summarize, label: "Summarize all", action: summarize),
                           morphs: false)
            }
        }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background { PageLight() }
        .foregroundStyle(Theme.ink)
        // Topics for pages saved elsewhere, and for any it couldn't choose before.
        .task(id: store.pages.map(\.id)) { store.sortNew() }
        // A moment after the last letter: it reads every page's text.
        .task(id: words) {
            let words = words, pages = store.pages
            guard !words.isEmpty else {
                found = []
                searchedFor = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) { SavedSearch.pages(pages, matching: words) }.value
            guard !Task.isCancelled else { return }
            found = matches
            searchedFor = words
        }
        .pullsDownToClose { close() }
        .onScrollPhaseChange { _, phase, context in
            guard phase == .idle else { return }
            isAtTop = context.geometry.contentOffset.y <= -context.geometry.contentInsets.top + 8
        }
    }

    // MARK: Header

    /// The pile still to read, fanned like papers set aside, beside how long it would take.
    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            if !unread.isEmpty { Pile(pages: Array(unread.prefix(3))) }
            VStack(alignment: .leading, spacing: 4) {
                // Beside the page on an open Duo it stays a list of its own.
                if browser.readLaterBeside {
                    Text("Read later")
                        .font(.system(size: 30, weight: .semibold))
                } else {
                    ReadingSwitch(current: .readLater)
                }
                if !unread.isEmpty {
                    Text("\(unread.count) to read, \(unread.map(\.minutes).reduce(0, +)) min")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Gathering

    /// Topic or date, or the search in their place.
    private var tools: some View {
        HStack(spacing: 8) {
            if isSearching {
                HStack(spacing: 8) {
                    Glyph(.search, size: 16).foregroundStyle(Theme.secondaryInk)
                    TextField("Search saved pages", text: $query)
                        .font(.system(size: 15))
                        .focused($isTyping)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // Not for a search come back to: its results are what's wanted.
                        .onAppear { isTyping = query.isEmpty }
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(Theme.raised))
                Button {
                    withAnimation(.snappy(duration: 0.28)) {
                        isSearching = false
                        query = ""
                    }
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
            } else {
                groupingSwitch
                Spacer(minLength: 0)
            }
        }
    }

    /// Everything that matched in one list: a search is read down, not across.
    @ViewBuilder private var results: some View {
        let pages = found.compactMap(store.page)
        if searchedFor == words {
            Text(pages.isEmpty ? "Nothing saved matches that." : pages.count == 1 ? "1 page" : "\(pages.count) pages")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .monospacedDigit()
                .plainRow(top: 8, bottom: 14)
        }
        ForEach(pages) { page in swipeableRow(page).plainRow(top: 0, bottom: 18) }
    }

    /// Topic or date, the one that's on on a raised capsule that slides across, as in Reader.
    private var groupingSwitch: some View {
        HStack(spacing: 0) {
            ForEach(SavedGrouping.allCases, id: \.self) { choice in
                Button {
                    withAnimation(.snappy(duration: 0.28)) { grouping = choice }
                } label: {
                    Text(choice.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(grouping == choice ? Theme.ink : Theme.secondaryInk)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            if grouping == choice { Capsule().fill(Theme.raised).matchedGeometryEffect(id: "grouping", in: switchSpace) }
                        }
                        .frame(height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group by \(choice.title.lowercased())")
                .accessibilityAddTraits(grouping == choice ? .isSelected : [])
            }
        }
    }

    /// Rows while they fit a column; past that, a shelf.
    @ViewBuilder private func rows(_ pages: [ReadLaterPage]) -> some View {
        if pages.count > Self.columnLength {
            shelf(pages).plainRow(top: 0, bottom: 18, side: 0)
        } else {
            ForEach(pages) { page in swipeableRow(page).plainRow(top: 0, bottom: 18) }
        }
    }

    /// Columns of four that swipe sideways and settle on a column, with the next
    /// one showing at the edge to say there's more. Rows here can't also swipe.
    private func shelf(_ pages: [ReadLaterPage]) -> some View {
        let columns = stride(from: 0, to: pages.count, by: Self.columnLength).map {
            Array(pages[$0..<min($0 + Self.columnLength, pages.count)])
        }
        return ScrollViewReader { shelf in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(columns.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(columns[index]) { page in row(page) }
                        }
                        .containerRelativeFrame(.horizontal) { width, _ in width - 62 }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 22, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onAppear {
                guard let returningTo, let column = columns.firstIndex(where: { $0.contains { $0.id == returningTo } }) else { return }
                shelf.scrollTo(column, anchor: .leading)
            }
        }
    }

    /// Its name, how many, and a summary of those pages alone.
    private func heading(_ section: SavedSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(section.isWaiting ? Theme.secondaryInk : Theme.ink)
            Text("\(section.pages.count)")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Theme.faintInk)
            Spacer(minLength: 12)
            if let group = section.group {
                Button { browser.summarizeSaved(group) } label: {
                    HStack(spacing: 6) {
                        Glyph(.summarize, size: 15, weight: 1.8)
                        Text("Summarize").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Summarize the \(group.pages.count) pages in \(group.name)")
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: A page

    /// A tap opens it, touch and hold offers the rest. A menu of its own, not
    /// `.contextMenu`: a list gives a row just one of those, so on a shelf, where
    /// one row holds many pages, it acted on the column's first page whichever was held.
    private func row(_ page: ReadLaterPage) -> some View {
        Menu {
            Button(page.isRead ? "Mark as unread" : "Mark as read") { toggleRead(page) }
            Button("Remove", role: .destructive) { remove(page) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                SavedPicture(page: page)
                    .frame(width: 68, height: 68)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.edge))
                    .opacity(page.isRead ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title)
                        .font(.system(size: 16, weight: page.isRead ? .regular : .medium))
                        .foregroundStyle(page.isRead ? Theme.secondaryInk : Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        SiteIcon(host: page.site, size: 13, remote: true)
                        Text(([page.site] + (page.text.isEmpty ? [] : ["\(page.minutes) min"]) + (page.isRead ? ["Read"] : [])).joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.faintInk)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            // The one open across the fold.
            .background {
                if browser.savedBeside == page.id {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised).padding(-8)
                }
            }
        }
        primaryAction: {
            withAnimation(.snappy(duration: 0.32)) { browser.openSaved(page, searching: isSearching ? words : "") }
        }
        .menuOrder(.fixed)
        .buttonStyle(RowButtonStyle())
        .accessibilityHint("Touch and hold to remove it, or to mark it read")
    }

    private func remove(_ page: ReadLaterPage) {
        guard let removed = ReadLater.shared.remove(page.id) else { return }
        browser.offerUndo("Removed from Saved") { ReadLater.shared.restore(removed) }
    }

    /// A row outside a shelf, where swiping is free to mean something.
    private func swipeableRow(_ page: ReadLaterPage) -> some View {
        row(page)
            // Not by a full swipe: one that long is too easily an accident.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { remove(page) } label: { Text("Remove") }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { toggleRead(page) } label: { Text(page.isRead ? "Unread" : "Read") }
                    .tint(Theme.secondaryInk)
            }
    }

    private func toggleRead(_ page: ReadLaterPage) {
        page.isRead ? ReadLater.shared.markUnread(page.id) : ReadLater.shared.markRead(page.id)
    }

    private func summarize() {
        browser.summarizeSaved()
    }

    /// The field at the top of the list, wherever the list was left.
    private func search(_ scroller: ScrollViewProxy) {
        guard !store.pages.isEmpty else {
            browser.showToast("Save a page first")
            return
        }
        // A field that's on its way takes the keys as it appears; asked now, it never gets them.
        if isSearching { isTyping = true }
        withAnimation(.snappy(duration: 0.28)) {
            isSearching = true
            scroller.scrollTo("top", anchor: .top)
        }
    }

    private func close() {
        browser.panel = .none
        browser.readLaterBeside = false
    }
}

/// Three pictures at most, fanned a few degrees apart, the newest on top.
private struct Pile: View {
    let pages: [ReadLaterPage]
    private static let angles: [Double] = [0, -9, 8]

    var body: some View {
        ZStack {
            ForEach(Array(pages.enumerated().reversed()), id: \.element.id) { index, page in
                SavedPicture(page: page)
                    .frame(width: 58, height: 74)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.edge))
                    .rotationEffect(.degrees(Self.angles[index]), anchor: .bottom)
                    .offset(x: CGFloat(index) * 7, y: CGFloat(index) * -2)
            }
        }
        .frame(width: 78, height: 84)
        .accessibilityHidden(true)
    }
}

/// A saved page's picture, from the file kept with it; the site's icon on the panel colour without one.
struct SavedPicture: View {
    let page: ReadLaterPage
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.raised
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                SiteIcon(host: page.site, size: 22, remote: true)
            }
        }
        .task(id: page.image) {
            guard let file = ReadLater.shared.imageURL(of: page) else { return }
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: file.path(percentEncoded: false))?.preparingForDisplay()
            }.value
        }
    }
}

extension View {
    /// A row with no list furniture: the canvas behind it, no separator, the page's own margins.
    func plainRow(top: CGFloat, bottom: CGFloat, side: CGFloat = 22) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Where a page was opened from in Saved, to go back to.
struct SavedPlace {
    let page: UUID
    let query: String
}
