import UIKit
import WebKit

/// A page put aside to read later, with its readable text as it was when
/// saved: it can be summarized offline, and the summary holds even if the
/// page changes or goes.
nonisolated struct ReadLaterPage: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var site: String
    var savedAt = Date.now
    /// Opened since it was saved.
    var readAt: Date?
    /// Paragraphs, headings and list items, as Readability found them; empty
    /// when the page had too little text to read.
    var text: String
    /// The page's share picture, or failing that, how it looked: a file in the folder.
    var image: String?
    /// Where the share picture came from, for the Mac's list (with sync on).
    var imageURL: URL?
    /// Why it was saved: a `SavedTopic`, chosen once and kept. Nil until then.
    /// Plain text, so a topic that's gone from a later version can't lose the list.
    var reason: String?

    var topic: SavedTopic { reason.flatMap(SavedTopic.init) ?? .other }
    var isRead: Bool { readAt != nil }
    var words: Int { SavedStats.words(in: text) }
    /// Minutes to read the page itself, at 230 words a minute.
    var minutes: Int { max(1, Int((Double(words) / 230).rounded())) }
}

/// The pages put aside, newest first, on this device: a JSON file and a
/// folder of pictures in Application Support, beside the other stores. With
/// sync on, the list (not the text) is the same on the Mac (RokoSync).
@Observable
final class ReadLater {
    static let shared = ReadLater()

    private(set) var pages: [ReadLaterPage] = []
    /// Summaries of several pages (a group's, or all of them), for the pages
    /// each was written from: opened again with nothing new, one shows at once
    /// and costs nothing. The last dozen.
    private(set) var digests: [Digest] = []
    /// Topics are being chosen for pages without one.
    private(set) var isSorting = false

    nonisolated struct Digest: Codable {
        let pageIDs: [UUID]
        let text: String
        let engine: String
        let note: String?
        let at: Date
    }

    private nonisolated struct Saved: Codable {
        var pages: [ReadLaterPage]
        var digests: [Digest]?
    }

    static let folder = URL.applicationSupportDirectory.appending(path: "read-later")
    private static var file: URL { URL.applicationSupportDirectory.appending(path: "read-later.json") }

    private init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        pages = saved.pages
        digests = saved.digests ?? []
    }

    var unread: [ReadLaterPage] { pages.filter { !$0.isRead } }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return pages.contains { Self.samePage($0.url, url) }
    }

    func page(_ id: UUID) -> ReadLaterPage? { pages.first { $0.id == id } }

    func imageURL(of page: ReadLaterPage) -> URL? {
        page.image.map { Self.folder.appending(path: $0) }
    }

    // MARK: Saving

    /// Saves the tab's page with its text, picture and site, or says it's already saved.
    func save(_ tab: BrowserTab) async -> String {
        guard let url = tab.url, let webView = tab.webView else { return "Nothing to save here" }
        if contains(url) { return "Already in Read Later" }
        let read = try? await PageReader.read(webView)
        var page = ReadLaterPage(url: url, title: read?.title.isEmpty == false ? read!.title : tab.displayTitle,
                             site: url.displayHost, text: read?.text ?? "")
        // Saved twice while the first was still being read.
        if contains(url) { return "Already in Read Later" }
        (page.image, page.imageURL) = await picture(for: page.id, webView: webView)
        pages.insert(page, at: 0)
        persist()
        sortNew()
        return "Saved to Read Later"
    }

    /// A story from the feed, with what's known of its text: the rest, and its
    /// picture, are read from the page, as for a page saved on the Mac.
    func save(_ story: NewsStory, text: String) {
        guard !contains(story.link) else { return }
        var page = ReadLaterPage(url: story.link, title: story.title, site: story.host, text: text)
        page.imageURL = story.image
        // From the news, so it's news: no need to ask.
        page.reason = SavedTopic.news.rawValue
        pages.insert(page, at: 0)
        persist()
        let id = page.id
        Task { await read(id) }
    }

    /// The page's share picture, kept here so the list has it offline; a
    /// snapshot of the page where it has none (or it won't load).
    private func picture(for id: UUID, webView: WKWebView) async -> (String?, URL?) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let name = "\(id.uuidString).jpg"
        let file = Self.folder.appending(path: name)
        let found = try? await webView.evaluateJavaScript("""
            (document.querySelector('meta[property="og:image"],meta[name="og:image"],meta[name="twitter:image"],meta[property="twitter:image"]') || {}).content || ""
            """) as? String
        if let found, !found.isEmpty, let base = webView.url,
           let address = URL(string: found, relativeTo: base)?.absoluteURL, address.scheme == "https",
           let (data, _) = try? await URLSession.quick.data(from: address),
           let image = UIImage(data: data), image.size.width >= 200,
           let jpeg = Self.thumbnail(image)?.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: file, options: .atomic)
            return (name, address)
        }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        if let shot = try? await webView.takeSnapshot(configuration: configuration),
           let jpeg = Self.thumbnail(shot)?.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: file, options: .atomic)
            return (name, nil)
        }
        return (nil, nil)
    }

    /// At most 480 pixels wide: the list shows it small.
    private static func thumbnail(_ image: UIImage) -> UIImage? {
        let width = min(image.size.width * image.scale, 480)
        let size = CGSize(width: width, height: image.size.height * width / image.size.width)
        return UIGraphicsImageRenderer(size: size, format: .init(for: .init(displayScale: 1))).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Changing

    func markRead(_ id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }), pages[index].readAt == nil else { return }
        pages[index].readAt = .now
        persist()
    }

    func markUnread(_ id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].readAt = nil
        persist()
    }

    func remove(_ id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if let file = imageURL(of: pages[index]) { try? FileManager.default.removeItem(at: file) }
        pages.remove(at: index)
        persist()
    }

    func keep(_ digest: Digest) {
        digests.removeAll { Set($0.pageIDs) == Set(digest.pageIDs) }
        digests = Array((digests + [digest]).suffix(12))
        persist()
    }

    /// A summary written from exactly these pages, if there is one.
    func digest(for pages: [ReadLaterPage]) -> Digest? {
        let ids = Set(pages.map(\.id))
        return digests.last { Set($0.pageIDs) == ids }
    }

    func pages(in group: ReadLaterGroup) -> [ReadLaterPage] {
        group.pages.compactMap(page)
    }

    /// Chooses a topic for each page that has none, one at a time and newest
    /// first, unread before read, as the model is slow. A page it couldn't answer
    /// for now waits for the next look at the list. Doesn't sync: each device
    /// sorts for itself.
    func sortNew() {
        guard !isSorting else { return }
        for index in pages.indices where pages[index].reason == nil {
            pages[index].reason = SavedTopics.evident(from: pages[index].url)?.rawValue
        }
        guard SavedTopics.canAsk, pages.contains(where: { $0.reason == nil }) else { return }
        isSorting = true
        Task(priority: .utility) {
            var unanswered = Set<UUID>()
            while true {
                let waiting = pages.filter { $0.reason == nil && !unanswered.contains($0.id) && !reading.contains($0.id) }
                guard let page = waiting.first(where: { !$0.isRead }) ?? waiting.first else { break }
                if let topic = await SavedTopics.topic(of: page), let index = pages.firstIndex(where: { $0.id == page.id }) {
                    pages[index].reason = topic.rawValue
                    write()
                } else {
                    unanswered.insert(page.id)
                }
            }
            isSorting = false
        }
    }

    /// Pages from elsewhere with their text still being fetched: not sorted without it.
    @ObservationIgnored private var reading = Set<UUID>()

    // MARK: From the Mac

    /// A page as the Mac has it: put in place, and one saved there read here
    /// for its text and picture, which the sync doesn't carry.
    func applySynced(_ record: LaterRecord, id: UUID) {
        guard let url = URL(string: record.url) else { return }
        if let index = pages.firstIndex(where: { $0.id == id }) {
            pages[index].title = record.title
            pages[index].readAt = record.readAt
            if let saved = record.savedAt { pages[index].savedAt = saved }
        } else {
            var page = ReadLaterPage(url: url, title: record.title, site: record.site ?? url.displayHost, text: "")
            page.id = id
            page.savedAt = record.savedAt ?? .now
            page.readAt = record.readAt
            page.imageURL = record.image.flatMap(URL.init(string:))
            pages.append(page)
            pages.sort { $0.savedAt > $1.savedAt }
            Task { await read(id) }
        }
        persist()
    }

    func removeSynced(_ id: UUID) {
        remove(id)
    }

    /// Fetches a page saved elsewhere and keeps its text and picture, as saving it here would.
    private func read(_ id: UUID) async {
        reading.insert(id)
        defer {
            reading.remove(id)
            sortNew()
        }
        guard let page = page(id),
              let (data, _) = try? await URLSession.quick.data(from: page.url) else { return }
        let html = String(decoding: data, as: UTF8.self)
        let text = WebResearcher.articleText(html, limit: 200_000)
            .replacingOccurrences(of: "\n", with: "\n\n")
        let pictureURL = page.imageURL ?? WebResearcher.shareImage(html, base: page.url)
        var name: String?
        if let pictureURL, let (bytes, _) = try? await URLSession.quick.data(from: pictureURL),
           let image = UIImage(data: bytes), let jpeg = Self.thumbnail(image)?.jpegData(compressionQuality: 0.8) {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            name = "\(id.uuidString).jpg"
            try? jpeg.write(to: Self.folder.appending(path: name!), options: .atomic)
        }
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if pages[index].text.isEmpty { pages[index].text = text }
        if let name { pages[index].image = name }
        pages[index].imageURL = pictureURL
        persist()
    }

    private func persist() {
        write()
        RokoSync.readLaterChanged()
    }

    private func write() {
        let saved = Saved(pages: pages, digests: digests)
        let file = Self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// The same page whatever its fragment.
    private static func samePage(_ a: URL, _ b: URL) -> Bool {
        func plain(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return plain(a) == plain(b)
    }
}
