import Foundation

/// A piece of the feed's page.
nonisolated enum FeedBlock: Identifiable, Equatable {
    /// Across the page, picture and all: what most sites covered, or a strong picture.
    case lead(FeedItem)
    case row(FeedItem)
    /// Two stories side by side.
    case pair(FeedStory, FeedStory)
    /// One site's further stories, as a list under its name.
    case site(String, [FeedStory])
    /// Stories with no picture, or a site's last few, as a list of lines.
    case brief([FeedStory])
    /// Newsletters, together.
    case mail([FeedStory])

    var id: String {
        switch self {
        case .lead(let item): "lead:" + item.id
        case .row(let item): "row:" + item.id
        case .pair(let first, _): "pair:" + first.id.absoluteString
        case .site(let host, _): "site:" + host
        case .brief(let stories): "brief:" + (stories.first?.id.absoluteString ?? "")
        case .mail: "mail"
        }
    }

    var stories: [FeedStory] {
        switch self {
        case .lead(let item), .row(let item): item.stories
        case .pair(let first, let second): [first, second]
        case .site(_, let stories), .brief(let stories), .mail(let stories): stories
        }
    }

    var unreadCount: Int {
        switch self {
        case .lead(let item), .row(let item): item.stories.allSatisfy(\.isRead) ? 0 : 1
        default: stories.filter { !$0.isRead }.count
        }
    }

    /// The same block with its stories as they are now: read ones stay where they were.
    func updated(_ current: [URL: FeedStory]) -> FeedBlock {
        func fresh(_ story: FeedStory) -> FeedStory { current[story.id] ?? story }
        func fresh(_ item: FeedItem) -> FeedItem {
            switch item {
            case .story(let story): .story(fresh(story))
            case .group(let stories): .group(stories.map(fresh))
            }
        }
        switch self {
        case .lead(let item): return .lead(fresh(item))
        case .row(let item): return .row(fresh(item))
        case .pair(let first, let second): return .pair(fresh(first), fresh(second))
        case .site(let host, let stories): return .site(host, stories.map(fresh))
        case .brief(let stories): return .brief(stories.map(fresh))
        case .mail(let stories): return .mail(stories.map(fresh))
        }
    }
}

/// Lays the feed out as a page, from what's in it rather than at random: the
/// most-covered event leads; a story with no picture goes in a list of lines
/// rather than beside an empty square; a site that posts all day keeps two
/// stories in the run of the page and the rest in a list under its name. Between
/// the big pieces, rows, a pair, and every few blocks a list, so no stretch of
/// the page is one thing repeated.
nonisolated enum FeedLayout {
    /// Stories of one site in the run of the page before the rest go to its list.
    private static let perSite = 2
    /// Blocks between a lead and the next one, at least.
    private static let leadEvery = 5
    /// Blocks between lists.
    private static let listEvery = 4
    private static let briefLength = 4

    static func compose(_ everything: [FeedItem]) -> [FeedBlock] {
        // Newsletters together, near the top: they're what you asked to be sent.
        let mail = everything.flatMap(\.stories).filter(\.story.isMail)
        let items = everything.filter { !$0.stories.contains(where: \.story.isMail) }
        var seen: [String: Int] = [:]
        var run: [FeedItem] = []
        var extras: [String: [FeedStory]] = [:]
        var briefs: [FeedStory] = []
        for item in items {
            guard case .story(let story) = item else {
                run.append(item)
                continue
            }
            let count = seen[story.story.host, default: 0]
            if count >= perSite {
                extras[story.story.host, default: []].append(story)
            } else if story.story.image == nil {
                briefs.append(story)
            } else {
                seen[story.story.host] = count + 1
                run.append(item)
            }
        }
        // A list of one or two is no list: they go with the lines.
        var lists: [FeedBlock] = []
        for (host, stories) in extras.sorted(by: { ($0.value.count, $0.key) > ($1.value.count, $1.key) }) {
            if stories.count >= 3 { lists.append(.site(host, stories)) } else { briefs += stories }
        }

        var blocks: [FeedBlock] = []
        var sinceLead = leadEvery
        var sinceList = 0
        var nextIsBrief = false
        func nextList() -> FeedBlock? {
            defer { nextIsBrief.toggle() }
            if nextIsBrief || lists.isEmpty, !briefs.isEmpty {
                let taken = Array(briefs.prefix(briefLength))
                briefs.removeFirst(taken.count)
                return .brief(taken)
            }
            return lists.isEmpty ? nil : lists.removeFirst()
        }
        var index = 0
        while index < run.count {
            let item = run[index]
            let next = run.indices.contains(index + 1) ? run[index + 1] : nil
            if item.picture != nil, sinceLead >= leadEvery || (item.sites >= 3 && sinceLead >= 2) {
                blocks.append(.lead(item))
                sinceLead = 0
            } else if sinceLead == 2, case .story(let first) = item, case .story(let second)? = next {
                blocks.append(.pair(first, second))
                index += 1
                sinceLead += 1
            } else {
                blocks.append(.row(item))
                sinceLead += 1
            }
            index += 1
            sinceList += 1
            if sinceList >= listEvery, let list = nextList() {
                blocks.append(list)
                sinceList = 0
            }
        }
        // What's left, so the page ends having shown everything: one list of
        // lines, not "Briefly" over and over.
        blocks += lists
        if !briefs.isEmpty { blocks.append(.brief(briefs)) }
        if !mail.isEmpty { blocks.insert(.mail(mail), at: min(1, blocks.count)) }
        return blocks
    }
}

extension FeedItem {
    /// The first picture among its stories.
    nonisolated var picture: URL? {
        stories.lazy.compactMap(\.story.image).first
    }
}
