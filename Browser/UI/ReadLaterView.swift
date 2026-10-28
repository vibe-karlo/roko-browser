import SwiftUI

/// The pages put aside, newest first: what's still to read, with pages on one
/// subject gathered under its name and a summary of just them a tap away, then
/// what's been opened. Tap one to read it (it counts as read); swipe left to
/// remove it, right to mark it read or not. The bar's middle writes one summary
/// across everything unread. Pull down past the top to close.
struct ReadLaterView: View {
    @Environment(BrowserModel.self) private var browser
    private var store: ReadLater { .shared }

    private var unread: [ReadLaterPage] { store.unread }
    private var read: [ReadLaterPage] { store.pages.filter(\.isRead) }
    /// Groups of unread pages; a page read since leaves its group.
    private var groups: [(ReadLaterGroup, [ReadLaterPage])] {
        store.groups.compactMap { group in
            let pages = store.pages(in: group).filter { !$0.isRead }
            return pages.count >= 2 ? (group, pages) : nil
        }
    }
    /// Unread pages in no group.
    private var alone: [ReadLaterPage] {
        let grouped = Set(groups.flatMap { $0.1.map(\.id) })
        return unread.filter { !grouped.contains($0.id) }
    }

    var body: some View {
        List {
            header
                .plainRow(top: 26, bottom: unread.isEmpty ? 8 : 22)
            if store.pages.isEmpty {
                Text("Nothing saved yet. Save a page from its tools, or type \u{201C}read later\u{201D} on it.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryInk)
                    .plainRow(top: 30, bottom: 0)
            }
            ForEach(groups, id: \.0.id) { group, pages in
                groupHeading(group, count: pages.count)
                    .plainRow(top: 8, bottom: 12)
                ForEach(pages) { page in row(page).plainRow(top: 0, bottom: 18) }
            }
            if !groups.isEmpty, !alone.isEmpty {
                Text("On their own")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .plainRow(top: 20, bottom: 14)
            }
            ForEach(alone) { page in row(page).plainRow(top: 0, bottom: 18) }
            if !read.isEmpty {
                Text("Read")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .plainRow(top: unread.isEmpty ? 8 : 20, bottom: 14)
                ForEach(read) { page in row(page).plainRow(top: 0, bottom: 18) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.3), value: store.pages)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ContextBar(leading: .init(glyph: .close, label: "Close", action: close),
                       glyph: .summarize, title: "Summarize all",
                       launch: summarize, morphs: false)
        }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        // Grouped afresh when the pages to read have changed since last time.
        .task(id: unread.map(\.id)) { await store.regroup() }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulled in
            if pulled { close() }
        }
    }

    // MARK: Header

    /// The pile still to read, fanned like papers set aside, beside how long it would take.
    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            if !unread.isEmpty { Pile(pages: Array(unread.prefix(3))) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Read later")
                    .font(.system(size: 30, weight: .semibold))
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

    // MARK: A group

    /// Its subject, how many, and a summary of those pages alone.
    private func groupHeading(_ group: ReadLaterGroup, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Theme.faintInk)
            Spacer(minLength: 12)
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
            .accessibilityLabel("Summarize the \(count) pages on \(group.name)")
        }
    }

    // MARK: A page

    private func row(_ page: ReadLaterPage) -> some View {
        Button { browser.openSaved(page) } label: {
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
                        Text(page.text.isEmpty ? page.site : "\(page.site) · \(page.minutes) min")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.faintInk)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { ReadLater.shared.remove(page.id) } label: { Text("Remove") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                page.isRead ? ReadLater.shared.markUnread(page.id) : ReadLater.shared.markRead(page.id)
            } label: { Text(page.isRead ? "Unread" : "Read") }
                .tint(Theme.secondaryInk)
        }
        .accessibilityHint("Swipe to remove it, or to mark it read")
    }

    private func summarize() {
        guard !unread.isEmpty else {
            browser.showToast(store.pages.isEmpty ? "Save a page first" : "Everything here is read")
            return
        }
        browser.summarizeSaved()
    }

    private func close() {
        browser.panel = .none
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

private extension View {
    /// A row with no list furniture: the canvas behind it, no separator, the page's own margins.
    func plainRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 22, bottom: bottom, trailing: 22))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
