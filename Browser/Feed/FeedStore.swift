import BackgroundTasks
import CryptoKit
import Foundation

/// A story in the feed, and whether it's been read.
nonisolated struct FeedStory: Codable, Identifiable, Equatable, Sendable {
    /// Without its text, which is kept in a file of its own.
    var story: NewsStory
    var firstSeen = Date.now
    var readAt: Date?

    var id: URL { story.link }
    var isRead: Bool { readAt != nil }
    /// When it came out, as far as anyone can tell.
    var when: Date { min(story.published ?? firstSeen, .now) }
}

/// What the feed lists: one story, or several sites' stories about one event.
nonisolated enum FeedItem: Identifiable, Equatable {
    case story(FeedStory)
    case group([FeedStory])

    var id: String {
        switch self {
        case .story(let story): story.id.absoluteString
        case .group(let stories): "group:" + (stories.first?.id.absoluteString ?? "")
        }
    }

    var stories: [FeedStory] {
        switch self {
        case .story(let story): [story]
        case .group(let stories): stories
        }
    }

    var when: Date { stories.map(\.when).max() ?? .distantPast }

    /// How much it matters, without knowing what anyone reads: how many sites
    /// have it counts most, then how many stories, then how new it is.
    var coverage: Double {
        let hours = max(0, -when.timeIntervalSinceNow / 3600)
        return pow(Double(sites), 1.5) * (1 + 0.25 * log(1 + Double(stories.count))) * exp(-hours / 18)
    }
    var sites: Int { Set(stories.map(\.story.host)).count }
}

/// What you follow, read into one list: the sources and topics Today uses, kept
/// with what's been read, each event once. A file of its own in Application
/// Support, with the articles' text beside it; read only when the feed opens.
/// It ends: two days back, and what's read goes out of the way.
@Observable
final class FeedStore {
    static let shared = FeedStore()

    private(set) var stories: [FeedStory] = []
    private(set) var refreshedAt: Date?
    private(set) var isRefreshing = false
    /// There's a newer layout than the one you're reading.
    private(set) var hasNewer = false
    /// The page: what was unread when it was laid out, in place even once it's
    /// read, so nothing moves under you. Laid out again each time it opens.
    private(set) var blocks: [FeedBlock] = []
    private(set) var readItems: [FeedItem] = []

    /// How far back the feed reaches.
    private static let reach: TimeInterval = 48 * 3600
    /// How long a story is remembered, so it doesn't come back unread.
    private static let memory: TimeInterval = 7 * 24 * 3600
    /// How long a newsletter stays: it isn't news that's over in a day or two.
    private static let mailReach: TimeInterval = 14 * 24 * 3600

    private nonisolated struct Saved: Codable {
        var stories: [FeedStory]
        var refreshedAt: Date?
        var verdicts: [String: [URL]]
        var comparisons: [ReadLater.Digest]
        var unsummarized: [URL]?
    }

    /// Candidate groups, as the headlines put them together.
    @ObservationIgnored private var candidates: [[NewsStory]] = []
    /// What a model made of a candidate group: the links it kept, by the group's links.
    @ObservationIgnored private var verdicts: [String: [URL]] = [:]
    /// Comparisons written, by the pages they're from: the last dozen.
    @ObservationIgnored private var comparisons: [ReadLater.Digest] = []
    /// Stories no model here would summarize: Summary isn't offered for them again.
    @ObservationIgnored private var unsummarized = Set<URL>()
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var pendingChecks: [[NewsStory]] = []
    @ObservationIgnored private var isReading = false
    /// Articles' own pictures, sharper than their feeds' thumbnails, for those shown large.
    @ObservationIgnored private var largePictures: [URL: URL] = [:]
    /// Stories mentioning a blocked word, as of the last look.
    @ObservationIgnored private var blocked = Set<URL>()

    private static var file: URL { URL.applicationSupportDirectory.appending(path: "feed.json") }
    private static let textFolder = URL.applicationSupportDirectory.appending(path: "feed-text")

    private init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        stories = saved.stories
        refreshedAt = saved.refreshedAt
        verdicts = saved.verdicts
        comparisons = saved.comparisons
        unsummarized = Set(saved.unsummarized ?? [])
    }

    /// Things left to read on the page: an event counts once.
    var unreadCount: Int { blocks.map(\.unreadCount).reduce(0, +) }

    var followsAnything: Bool { !NewsSite.chosen.isEmpty || !NewsTopics.chosen.isEmpty || Newsletters.isOn }

    func follows(host: String) -> Bool { NewsSite.chosen.contains { $0.host == host } }

    // MARK: Reading the sources

    // MARK: With roko closed

    static let taskID = "com.growthstudio.roko.feed"

    /// Asks iOS to wake roko now and then, so the feed is ready when it's opened.
    /// iOS picks the moment, and how often, from how much roko is used.
    static func scheduleRefresh() {
        guard !NewsSite.chosen.isEmpty || !NewsTopics.chosen.isEmpty || Newsletters.isOn else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = .now.addingTimeInterval(2 * 3600)
        Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
    }

    /// The feed has opened: laid out from what's known, then what's new read.
    func opened() async {
        isReading = false
        hasNewer = false
        await regroup()
        rebuild()
        await refreshIfStale()
    }

    /// You've scrolled or tapped: from now on nothing moves until you say.
    func noteReading() { isReading = true }

    func showNewer() {
        hasNewer = false
        isReading = false
        rebuild()
    }

    /// When it's been a quarter of an hour.
    func refreshIfStale() async {
        if refreshedAt.map({ $0 < .now.addingTimeInterval(-15 * 60) }) ?? true { await refresh() }
    }

    /// `immediately` when asked for, so what comes back shows at once.
    func refresh(immediately: Bool = false, inBackground: Bool = false) async {
        if immediately { isReading = false }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let sources = NewsSite.chosen
        let topics = NewsTopics.chosen
        // Topics are looked for in the major feeds too, as in Today.
        let pool = topics.isEmpty ? [] : TodayNews.topicPool.filter { extra in !sources.contains { $0.id == extra.id } }
        let byID = await TodayNews.stories(of: sources + pool, keepingBodies: true)
        var read = sources.flatMap { byID[$0.id] ?? [] }
        let everything = byID.values.flatMap { $0 }
        for topic in topics {
            read += await TodayNews.about(topic, in: everything, count: 12)
        }
        // And each topic across the web, not only among the sites read here.
        read += await withTaskGroup(of: [NewsStory].self) { group in
            for topic in topics { group.addTask { await SiteRoutes.search(topic) } }
            var found: [NewsStory] = []
            for await stories in group { found += TodayNews.recent(stories, hours: 48).prefix(10) }
            return found
        }
        read += await Newsletters.fetch(inBackground: inBackground)
        // Nothing came back (offline, say): what was there stays.
        guard !read.isEmpty else {
            await regroup()
            publish()
            return
        }
        merge(read)
        refreshedAt = .now
        await regroup()
        publish()
        persist()
    }

    private func merge(_ read: [NewsStory]) {
        var known = Dictionary(stories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var bodies: [(URL, String)] = []
        for var story in read {
            if let body = story.content { bodies.append((story.link, body)) }
            story.content = nil
            if var existing = known[story.link] {
                existing.story = story
                known[story.link] = existing
            } else {
                known[story.link] = FeedStory(story: story)
            }
        }
        let oldest = Date.now.addingTimeInterval(-Self.memory)
        let oldestMail = Date.now.addingTimeInterval(-Self.mailReach)
        let (kept, gone) = known.values.reduce(into: ([FeedStory](), [FeedStory]())) { result, story in
            let limit = story.story.isMail ? oldestMail : oldest
            if story.firstSeen > limit || story.when > limit { result.0.append(story) } else { result.1.append(story) }
        }
        stories = kept.sorted { $0.when > $1.when }
        let goneFiles = gone.map { Self.textFile(for: $0.id) }
        for story in gone where story.story.isMail { Newsletters.forget(story.id) }
        let writes = bodies.map { (Self.textFile(for: $0.0), $0.1) }
        let folder = Self.textFolder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, body) in writes { try? body.write(to: file, atomically: true, encoding: .utf8) }
            for file in goneFiles { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Grouping

    private var recent: [FeedStory] {
        let reach = Date.now.addingTimeInterval(-Self.reach)
        let mailReach = Date.now.addingTimeInterval(-Self.mailReach)
        return stories.filter { $0.when > ($0.story.isMail ? mailReach : reach) }
    }

    private func regroup() async {
        let reading = recent.map { ($0.story, Self.textFile(for: $0.id)) }
        let terms = NewsBlocks.chosen
        // Off the main thread: with words to block, it reads each story's kept text.
        (blocked, candidates) = await Task.detached(priority: .userInitiated) {
            // Nothing to look for: no story's text needs reading.
            let blocked = terms.isEmpty ? Set<URL>() : Set(reading.filter { story, file in
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                return NewsBlocks.mention(terms, in: [story.title, story.summary ?? "", text].joined(separator: " "))
            }.map(\.0.link))
            return (blocked, StoryGroups.candidates(reading.map(\.0).filter { !blocked.contains($0.link) && !$0.isMail }))
        }.value
        // Verdicts on groups that are gone would only pile up.
        verdicts = verdicts.filter { key, _ in candidates.contains { Self.key($0) == key } }
    }

    /// Lays the page out with what's new, unless that would move it under you.
    private func publish() {
        if isReading {
            hasNewer = true
        } else {
            rebuild()
        }
    }

    /// A group has come on screen: a model looks at it, if none has. Only these:
    /// groups nobody scrolled to cost nothing, on the battery or a Claude key.
    func wantCheck(_ stories: [FeedStory]) {
        guard stories.count >= 2, StoryGroups.canConfirm, let candidate = candidate(of: stories),
              verdicts[Self.key(candidate)] == nil, !pendingChecks.contains(where: { Self.key($0) == Self.key(candidate) }) else { return }
        pendingChecks.append(candidate)
        Task { await runChecks() }
    }

    /// Scrolled past before its turn came.
    func dropCheck(_ stories: [FeedStory]) {
        guard let candidate = candidate(of: stories) else { return }
        pendingChecks.removeAll { Self.key($0) == Self.key(candidate) }
    }

    private func candidate(of stories: [FeedStory]) -> [NewsStory]? {
        guard let first = stories.first?.id else { return nil }
        return candidates.first { $0.contains { $0.link == first } }
    }

    /// One at a time, the one that came on screen last first.
    private func runChecks() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        while let group = pendingChecks.popLast() {
            let kept = await StoryGroups.confirm(group).map(\.link)
            verdicts[Self.key(group)] = kept
            settle(group, keeping: Set(kept))
            persist()
        }
    }

    /// A group the model split, put right where it is. Those it took out come
    /// back on their own the next time the page is laid out.
    private func settle(_ group: [NewsStory], keeping kept: Set<URL>) {
        let members = Set(group.map(\.link))
        func settled(_ item: FeedItem) -> FeedItem {
            guard case .group(let stories) = item, stories.contains(where: { members.contains($0.id) }) else { return item }
            let left = stories.filter { kept.contains($0.id) }
            if StoryGroups.spansSites(left.map(\.story)) { return .group(left) }
            return left.first.map(FeedItem.story) ?? item
        }
        blocks = blocks.map { block in
            switch block {
            case .lead(let item): .lead(settled(item))
            case .row(let item): .row(settled(item))
            default: block
            }
        }
    }

    private static func key(_ group: [NewsStory]) -> String {
        group.map(\.link.absoluteString).sorted().joined(separator: "\n")
    }

    /// Lays the page out afresh: events several sites covered first, then
    /// the rest newest first. Read stories go below it.
    func rebuild() {
        let byLink = Dictionary(recent.filter { !blocked.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped = Set<URL>()
        var groups: [[FeedStory]] = []
        for candidate in candidates {
            let links = verdicts[Self.key(candidate)] ?? candidate.map(\.link)
            let members = links.compactMap { byLink[$0] }
            guard StoryGroups.spansSites(members.map(\.story)) else { continue }
            groups.append(members)
            grouped.formUnion(members.map(\.id))
        }
        let items = groups.map { FeedItem.group($0) } + byLink.values.filter { !grouped.contains($0.id) }.map { FeedItem.story($0) }
        let unread = items.filter { $0.stories.contains { !$0.isRead } }
        // What most sites covered leads, or failing that the newest event with a picture.
        var leading = unread.filter { $0.sites >= 3 }.sorted { $0.coverage > $1.coverage }
        if leading.isEmpty, let first = unread.filter({ $0.sites >= 2 && $0.picture != nil }).max(by: { $0.coverage < $1.coverage }) {
            leading = [first]
        }
        let led = Set(leading.map(\.id))
        blocks = FeedLayout.compose(leading + unread.filter { !led.contains($0.id) }.sorted { $0.when > $1.when })
        readItems = items.filter { $0.stories.allSatisfy(\.isRead) }.sorted { $0.when > $1.when }
    }

    // MARK: Changing

    func markRead(_ links: [URL]) {
        isReading = true
        setRead(links, at: .now)
    }

    func markUnread(_ links: [URL]) { setRead(links, at: nil) }

    private func setRead(_ links: [URL], at date: Date?) {
        let links = Set(links)
        for index in stories.indices where links.contains(stories[index].id) {
            stories[index].readAt = date
        }
        let current = Dictionary(stories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        blocks = blocks.map { $0.updated(current) }
        persist()
    }

    // MARK: Articles

    /// Long enough to be the article, not a feed's opening lines.
    private static let wholeArticle = 1_200

    private static func textFile(for link: URL) -> URL {
        let hash = SHA256.hash(data: Data(link.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return textFolder.appending(path: String(hash.prefix(32)) + ".txt")
    }

    func keptText(of link: URL) -> String? {
        try? String(contentsOf: Self.textFile(for: link), encoding: .utf8)
    }

    /// The article to read: from the feed when it gave the whole of it,
    /// otherwise read from the page by Readability, off screen, and kept.
    func readable(_ story: NewsStory) async -> ReadablePage? {
        let kept = keptText(of: story.link).map(PageReader.withoutFurniture)
        // A newsletter's text is whatever came with it: there's no page to go and read.
        if story.isMail { return ReadablePage(title: story.title, site: story.from ?? story.host, text: kept ?? "", isArticle: true) }
        if let kept, kept.count >= Self.wholeArticle {
            return ReadablePage(title: story.title, site: story.host, text: kept, isArticle: true)
        }
        guard let found = await RenderedPage.readable(of: story.link) else {
            return kept.map { ReadablePage(title: story.title, site: story.host, text: $0, isArticle: true) }
        }
        let page = found
        if page.isArticle {
            let file = Self.textFile(for: story.link)
            try? FileManager.default.createDirectory(at: Self.textFolder, withIntermediateDirectories: true)
            try? page.text.write(to: file, atomically: true, encoding: .utf8)
        }
        return page
    }

    /// The article's text, to compare it with others': quickly from the page's
    /// plain address where that's enough, without running its scripts.
    func text(of story: NewsStory) async -> String {
        if let kept = keptText(of: story.link), kept.count >= Self.wholeArticle { return kept }
        if let html = await TodayNews.text(at: story.link) {
            let text = WebResearcher.articleText(html, limit: 200_000)
            if text.count >= Self.wholeArticle { return PageReader.withoutFurniture(text) }
        }
        return await readable(story)?.text ?? keptText(of: story.link) ?? story.summary ?? ""
    }

    /// The article's own share picture, once per story.
    func largePicture(of link: URL) async -> URL? {
        if let known = largePictures[link] { return known }
        let found = await WebResearcher.shareImage(of: link)
        if let found { largePictures[link] = found }
        return found
    }

    func canSummarize(_ link: URL) -> Bool { !unsummarized.contains(link) }

    func noteNoSummary(for link: URL) {
        unsummarized.insert(link)
        persist()
    }

    // MARK: Comparisons

    /// A page of a comparison, with the same id whenever it's the same story.
    static func pageID(for link: URL) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(link.absoluteString.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func comparison(of pages: [ReadLaterPage]) -> ReadLater.Digest? {
        let ids = Set(pages.map(\.id))
        return comparisons.last { Set($0.pageIDs) == ids }
    }

    func keep(_ comparison: ReadLater.Digest) {
        comparisons.removeAll { Set($0.pageIDs) == Set(comparison.pageIDs) }
        comparisons = Array((comparisons + [comparison]).suffix(12))
        persist()
    }

    private func persist() {
        let saved = Saved(stories: stories, refreshedAt: refreshedAt, verdicts: verdicts, comparisons: comparisons,
                          unsummarized: Array(unsummarized))
        let file = Self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }
}
