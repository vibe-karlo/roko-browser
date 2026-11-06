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
    /// Articles' own pictures, sharper than their feeds' thumbnails, for those shown
    /// large. Nil for a story whose feed's picture will do.
    @ObservationIgnored private var largePictures: [URL: URL?] = [:]
    /// In pixels. On the sites tried, thumbnails are 240 wide and the rest 700 or more.
    private static let properPictureWidth = 600
    /// Stories not to show, as of the last look: mentioning a blocked word, asked to
    /// see less of, or from a site or topic no longer followed.
    @ObservationIgnored private var blocked = Set<URL>()
    /// Stories a little like one asked to see less of: last on the page, never leading.
    @ObservationIgnored private var lowered = Set<URL>()
    /// Stories whose pages have been asked for a picture, while roko's open.
    @ObservationIgnored private var picturesLookedFor = Set<URL>()
    private static let picturesPerRead = 36
    /// Sources changed while reading the old ones: read again when that's done.
    @ObservationIgnored private var readsAgain = false

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
        guard !isRefreshing else {
            if immediately { readsAgain = true }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if readsAgain {
                readsAgain = false
                Task { await refresh(immediately: true) }
            }
        }
        let sources = NewsSite.chosen
        let topics = NewsTopics.chosen
        // Topics are looked for in the major feeds too, as in Today.
        let pool = topics.isEmpty ? [] : TodayNews.topicPool.filter { extra in !sources.contains { $0.id == extra.id } }
        let byID = await TodayNews.stories(of: sources + pool, keepingBodies: true)
        var read = sources.flatMap { byID[$0.id] ?? [] }
        let everything = byID.values.flatMap { $0 }
        // Each topic across the web too, not only among the sites read here.
        let web = await withTaskGroup(of: (String, [NewsStory]).self) { group in
            for topic in topics { group.addTask { (topic, await SiteRoutes.search(topic)) } }
            var found: [String: [NewsStory]] = [:]
            for await (topic, stories) in group { found[topic] = stories }
            return found
        }
        // One look at both: search brings pages that only rank for the words.
        for topic in topics {
            read += await TodayNews.about(topic, in: everything + (web[topic] ?? []), count: 20)
        }
        read += await Newsletters.fetch(inBackground: inBackground)
        // Nothing came back (offline, say): what was there stays.
        guard !read.isEmpty else {
            await regroup()
            publish()
            return
        }
        if !inBackground { read = await withPictures(read) }
        merge(read)
        refreshedAt = .now
        await regroup()
        publish()
        persist()
    }

    /// A sitemap or a search names no pictures, but each story's page does, in its head.
    /// The newest few at a time, once each: what's found is kept with the story.
    private func withPictures(_ read: [NewsStory]) async -> [NewsStory] {
        let pictured = Set(stories.filter { $0.story.image != nil }.map(\.id))
        let wanted = TodayNews.recent(read.filter { $0.image == nil && !$0.isMail && !pictured.contains($0.link) && !picturesLookedFor.contains($0.link) }, hours: 48)
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            .prefix(Self.picturesPerRead)
        picturesLookedFor.formUnion(wanted.map(\.link))
        var found: [URL: URL] = [:]
        for start in stride(from: 0, to: wanted.count, by: 6) {
            let batch = wanted.dropFirst(start).prefix(6)
            await withTaskGroup(of: (URL, URL?).self) { group in
                for story in batch { group.addTask { (story.link, await WebResearcher.shareImage(of: story.link)) } }
                for await (link, picture) in group { found[link] = picture }
            }
        }
        return read.map { story in
            var story = story
            if story.image == nil { story.image = found[story.link] }
            return story
        }
    }

    private func merge(_ read: [NewsStory]) {
        var known = Dictionary(stories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var bodies: [(URL, String, [PageLink])] = []
        for var story in read {
            if let body = story.content { bodies.append((story.link, body, story.links ?? [])) }
            story.content = nil
            story.links = nil
            if var existing = known[story.link] {
                // What a page gave stays: the next read of a sitemap won't name it either.
                story.image = story.image ?? existing.story.image
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
        let goneFiles = gone.flatMap { [Self.textFile(for: $0.id), Self.linksFile(for: $0.id)] }
        for story in gone where story.story.isMail { Newsletters.forget(story.id) }
        let writes = bodies.map { (Self.textFile(for: $0.0), $0.1, Self.linksFile(for: $0.0), $0.2) }
        let folder = Self.textFolder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, body, linksFile, links) in writes {
                try? body.write(to: file, atomically: true, encoding: .utf8)
                try? JSONEncoder().encode(links).write(to: linksFile, options: .atomic)
            }
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
        let less = NewsLess.chosen
        let hidden = NewsHiddenSites.chosen
        let hosts = Set(NewsSite.chosen.map(\.host))
        let topics = NewsTopics.chosen
        // Off the main thread: with words to block, it reads each story's kept text.
        (blocked, lowered, candidates) = await Task.detached(priority: .userInitiated) {
            let lessLinks = Set(less.flatMap(\.links))
            var lowered = Set<URL>()
            let blocked = Set(reading.filter { story, file in
                if story.isMail { return false }
                if NewsHiddenSites.hides(story.host, in: hidden) { return true }
                // What a topic or site brought goes when it does.
                if !hosts.contains(story.host), !topics.contains(where: { TodayNews.names($0, story) }) { return true }
                if lessLinks.contains(story.link) { return true }
                let closeness = NewsLess.closeness(of: story.title, to: less)
                if closeness >= 2 { return true }
                if closeness == 1 { lowered.insert(story.link) }
                // Nothing to look for: no story's text needs reading.
                guard !terms.isEmpty else { return false }
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                return NewsBlocks.mention(terms, in: [story.title, story.summary ?? "", text].joined(separator: " "))
            }.map(\.0.link))
            return (blocked, lowered, StoryGroups.candidates(reading.map(\.0).filter { !blocked.contains($0.link) && !$0.isMail }))
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
        let sunk = unread.filter { $0.stories.allSatisfy { lowered.contains($0.id) } }
        let sunkIDs = Set(sunk.map(\.id))
        let standing = unread.filter { !sunkIDs.contains($0.id) }
        // What most sites covered leads, or failing that the newest event with a picture.
        var leading = standing.filter { $0.sites >= 3 }.sorted { $0.coverage > $1.coverage }
        if leading.isEmpty, let first = standing.filter({ $0.sites >= 2 && $0.picture != nil }).max(by: { $0.coverage < $1.coverage }) {
            leading = [first]
        }
        let led = Set(leading.map(\.id))
        blocks = FeedLayout.compose(leading + standing.filter { !led.contains($0.id) }.sorted { $0.when > $1.when }
                                    + sunk.sorted { $0.when > $1.when }, neverLeading: sunkIDs)
        readItems = items.filter { $0.stories.allSatisfy(\.isRead) }.sorted { $0.when > $1.when }
    }

    // MARK: Changing

    func markRead(_ links: [URL]) {
        isReading = true
        setRead(links, at: .now)
    }

    func markUnread(_ links: [URL]) { setRead(links, at: nil) }

    /// Off the page now, and what's like it from now on. You asked, so the page may move.
    func showLess(_ shown: [NewsStory]) async {
        NewsLess.chosen.insert(NewsLess.entry(for: shown, among: recent.map(\.story.title)), at: 0)
        await regroup()
        rebuild()
    }

    /// Nothing more from this site, here or in Today: off the page now, and no longer followed.
    func dontShow(host: String) async {
        let hidden = [host]
        let followed = NewsSite.chosen.contains { NewsHiddenSites.hides($0.host, in: hidden) }
        NewsHiddenSites.hide(host)
        await regroup()
        rebuild()
        if followed { TodayModel.shared.sitesChanged() } else { TodayModel.shared.applyLess() }
    }

    /// Don't Show taken back: its stories return, and it's followed again if it was.
    func showAgain(host: String) async {
        NewsHiddenSites.chosen.removeAll { $0 == host }
        NewsSite.chosen += NewsHiddenSites.takeBack([host])
        await regroup()
        rebuild()
        TodayModel.shared.sitesChanged()
    }

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

    /// The words in a kept text that link somewhere, beside it.
    private static func linksFile(for link: URL) -> URL {
        textFile(for: link).deletingPathExtension().appendingPathExtension("links")
    }

    private func keptLinks(of link: URL) -> [PageLink] {
        (try? Data(contentsOf: Self.linksFile(for: link))).flatMap { try? JSONDecoder().decode([PageLink].self, from: $0) } ?? []
    }

    func keptText(of link: URL) -> String? {
        try? String(contentsOf: Self.textFile(for: link), encoding: .utf8)
    }

    /// The article to read: from the feed when it gave the whole of it,
    /// otherwise read from the page by Readability, off screen, and kept.
    func readable(_ story: NewsStory) async -> ReadablePage? {
        let kept = keptText(of: story.link).map { PageReader.withoutFurniture($0, forMail: story.isMail) }
        // A newsletter's text is whatever came with it: there's no page to go and read.
        if story.isMail {
            return ReadablePage(title: story.title, site: story.from ?? story.host, text: kept ?? "", isArticle: true, links: Newsletters.links(of: story.link, in: kept ?? ""))
        }
        if let kept, kept.count >= Self.wholeArticle {
            return ReadablePage(title: story.title, site: story.host, text: kept, isArticle: true, links: keptLinks(of: story.link))
        }
        guard let found = await RenderedPage.readable(of: story.link) else {
            return kept.map { ReadablePage(title: story.title, site: story.host, text: $0, isArticle: true, links: keptLinks(of: story.link)) }
        }
        let page = found
        if page.isArticle {
            let file = Self.textFile(for: story.link)
            try? FileManager.default.createDirectory(at: Self.textFolder, withIntermediateDirectories: true)
            try? page.text.write(to: file, atomically: true, encoding: .utf8)
            try? JSONEncoder().encode(page.links).write(to: Self.linksFile(for: story.link), options: .atomic)
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

    /// The article's own share picture, once per story, when its feed's is only a
    /// thumbnail: BBC's are 240 wide. A proper picture stays, as a share picture is
    /// a banner for link previews, no sharper copy of it: The Verge's 2700 wide
    /// would give way to 1200, The Guardian's whole photo to its top half under
    /// the paper's name.
    func largePicture(of story: NewsStory) async -> URL? {
        if let known = largePictures[story.link] { return known }
        if let image = story.image, let width = await WebResearcher.pixelWidth(of: image), width >= Self.properPictureWidth {
            largePictures.updateValue(nil, forKey: story.link)
            return nil
        }
        // Not kept when there's none: scrolling away cancels the look, as does a bad connection.
        let found = await WebResearcher.shareImage(of: story.link)
        if let found { largePictures[story.link] = found }
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
        // Not one in an old shape, led by what they agree on or translated by Apple's
        // models, which turned "arrested" into "killed": it's done again in the new.
        return comparisons.last { digest in
            Set(digest.pageIDs) == ids && !digest.text.contains("All agree") && !digest.text.contains("Svi se slažu") && digest.note?.contains("In English") != true
        }
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
