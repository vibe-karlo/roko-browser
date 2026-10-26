import Foundation
import FoundationModels

/// A news source for Today: a whole site (its stories compete for Top
/// stories), or one section of a site, "glas-slavonije.hr/sport/nk-osijek",
/// which gets a section of its own. Read from its feed, or, for sites
/// without one, from the page itself.
nonisolated struct NewsSite: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Its host, "index.hr", for the icon and the line under each story.
    var host: String
    var feed: URL?
    /// A section's path, "/sport/nk-osijek"; nil for a whole site.
    var path: String? = nil
    /// A page read for its headlines, when the site has no feed for it.
    var page: URL? = nil
    /// What the section is called, "NK Osijek".
    var name: String? = nil

    var id: String { host + (path ?? "") }
    var isSection: Bool { path != nil }
    var title: String { name ?? host }

    /// Well-known sites with their feeds, to pick from without typing.
    static let suggestions: [NewsSite] = [
        ("index.hr", "https://www.index.hr/rss"),
        ("jutarnji.hr", "https://www.jutarnji.hr/feed"),
        ("vecernji.hr", "https://www.vecernji.hr/feeds/latest"),
        ("n1info.hr", "https://n1info.hr/feed/"),
        ("telegram.hr", "https://www.telegram.hr/feed/"),
        ("tportal.hr", "https://www.tportal.hr/rss"),
        ("24sata.hr", "https://www.24sata.hr/feeds/news.xml"),
        ("net.hr", "https://net.hr/feed"),
        ("dnevnik.hr", "https://www.dnevnik.hr/assets/feed/articles"),
        ("bbc.com", "https://feeds.bbci.co.uk/news/rss.xml"),
        ("theguardian.com", "https://www.theguardian.com/world/rss"),
        ("theverge.com", "https://www.theverge.com/rss/index.xml"),
        ("news.ycombinator.com", "https://hnrss.org/frontpage"),
    ].map { NewsSite(host: $0.0, feed: URL(string: $0.1)) }

    // MARK: Chosen sources

    static let key = "today.newsSites"

    static var chosen: [NewsSite] {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([NewsSite].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

/// A subject to follow in Today, "NK Osijek": stories about it from all the
/// sources roko reads, whichever site they're on.
nonisolated enum NewsTopics {
    static let key = "today.topics"

    static var chosen: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// One story from a feed or a page.
nonisolated struct NewsStory: Codable, Equatable, Hashable, Identifiable, Sendable {
    let title: String
    let link: URL
    let host: String
    let published: Date?
    /// The feed's short description, when it has one: topics are matched on it too.
    var summary: String? = nil
    var id: URL { link }
}

/// A section of Today besides Top stories: one followed page, or one topic.
nonisolated struct FollowedSection: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// The site, for a page's section; nil for a topic, which spans sites.
    let host: String?
    let stories: [NewsStory]
}

/// Reads the chosen sources and has Apple's on-device model pick from them.
/// It only picks: headlines stay in the sites' own words, so nothing is lost
/// in translation and nothing is paid for.
nonisolated enum TodayNews {
    // MARK: Adding a source

    /// Finds how to read an address: a whole site's feed, or for a section
    /// ("…/sport/nk-osijek/"), a feed of just that section, or else the
    /// section page itself. Never the whole site's feed for a section: only
    /// that section was asked for.
    @concurrent static func find(_ address: String) async -> NewsSite? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), let rawHost = url.host() else { return nil }
        let host = rawHost.lowercased().hasPrefix("www.") ? String(rawHost.lowercased().dropFirst(4)) : rawHost.lowercased()
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let isSection = !path.isEmpty
        if !isSection, let known = NewsSite.suggestions.first(where: { $0.host == host }) { return known }

        let html = await text(at: url)
        let declared = html.map { feedLinks(in: $0, base: url) } ?? []
        var candidates: [URL]
        if isSection {
            // A feed the page names for itself, then the usual feed beside it.
            let base = url.absoluteString.hasSuffix("/") ? url : url.appending(path: "")
            candidates = declared.filter { $0.path(percentEncoded: false).contains("/" + path) }
                + ["feed", "rss", "feed.xml", "rss.xml"].compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        } else {
            candidates = declared + ["feed", "rss", "rss.xml", "feed.xml", "index.xml", "feeds/posts/default"]
                .compactMap { URL(string: "/" + $0, relativeTo: url)?.absoluteURL }
        }
        let name = isSection ? sectionName(path: path, pageTitle: html.flatMap(pageTitle)) : nil
        for candidate in candidates {
            if let stories = await stories(from: candidate, host: host), stories.count >= 3 {
                return NewsSite(host: host, feed: candidate, path: isSection ? "/" + path : nil, name: name)
            }
        }
        // No feed: the page itself, if it lists enough stories to follow.
        if let html, PageHeadlines.parse(html, page: url, host: host).count >= 3 {
            return NewsSite(host: host, feed: nil, path: isSection ? "/" + path : nil, page: url, name: name)
        }
        return nil
    }

    /// "Sportske novosti - HNL" for …/nogomet/hnl gives "HNL"; a page with no
    /// title gives its address: "nk-osijek" → "NK Osijek".
    private static func sectionName(path: String, pageTitle: String?) -> String {
        let slug = path.split(separator: "/").last.map(String.init) ?? path
        let words = slug.split(separator: "-").map { word -> String in
            let lower = word.lowercased()
            let hasVowel = lower.contains { "aeiou".contains($0) }
            return lower.count <= 2 || !hasVowel ? lower.uppercased() : lower.prefix(1).uppercased() + lower.dropFirst()
        }
        let fromSlug = words.joined(separator: " ")
        if let pageTitle {
            let parts = pageTitle.components(separatedBy: CharacterSet(charactersIn: "|–-")).map { $0.trimmingCharacters(in: .whitespaces) }
            let folded = fromSlug.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let match = parts.first(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded }) {
                return match
            }
        }
        return fromSlug
    }

    private static func pageTitle(_ html: String) -> String? {
        let title = html.firstMatch(of: /<title[^>]*>([^<]*)<\/title>/)?.1 ?? ""
        let trimmed = String(title).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : PageHeadlines.decode(trimmed)
    }

    // MARK: Reading

    /// A source's newest stories.
    @concurrent static func stories(of source: NewsSite) async -> [NewsStory] {
        if let feed = source.feed { return await stories(from: feed, host: source.host) ?? [] }
        if let page = source.page, let html = await text(at: page) {
            return await Task.detached(priority: .utility) { PageHeadlines.parse(html, page: page, host: source.host) }.value
        }
        return []
    }

    /// The stories of several sources, read at once, each source's newest first.
    @concurrent static func stories(of sources: [NewsSite]) async -> [String: [NewsStory]] {
        await withTaskGroup(of: (String, [NewsStory]).self) { group in
            for source in sources {
                group.addTask { (source.id, await stories(of: source)) }
            }
            var all: [String: [NewsStory]] = [:]
            for await (id, stories) in group { all[id] = stories }
            return all
        }
    }

    /// From the last day and a half, newest first (all of them if none are dated that recently).
    static func recent(_ stories: [NewsStory], hours: Double = 36) -> [NewsStory] {
        let recent = stories.filter { ($0.published ?? .now) > .now.addingTimeInterval(-hours * 3600) }
        return (recent.isEmpty ? stories : recent).sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
    }

    // MARK: Top stories

    /// The day's most important stories, picked by Apple's on-device model.
    /// Without the model (or if it fails), each site's newest. Either way, at
    /// most two from one site, and never the same story twice: the small
    /// model was asked not to and still picked one crash from two sites.
    @MainActor static func top(_ stories: [NewsStory], count: Int = 6) async -> [NewsStory] {
        let newest = stories.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        guard AppleModels.onDeviceAvailable, stories.count > count else { return varied(newest, count: count) }
        // Each site's newest in turn: taken newest-first overall, a site that
        // posts all day (index.hr) filled the list and the others went unseen.
        let offered = balanced(newest, limit: 60)
        let numbered = offered.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.host))" }
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: """
            You are an editor choosing a front page. From today's headlines, pick the stories that matter \
            most to a general reader: big national and world news, and things that affect daily life. \
            Several headlines about the same event are one story: pick only its most informative one. \
            Leave out gossip, quizzes, horoscopes, promotions and deals, reviews, videos, minor sport, and \
            event listings or what's-on notices (a concert, a party, a club night, a mass, a film programme).
            """)
        let prompt = "Headlines:\n" + numbered.joined(separator: "\n") + "\n\nPick the \(count + 4) most important."
        guard let picks = try? await session.respond(to: prompt, generating: FrontPage.self).content.numbers else {
            return varied(newest, count: count)
        }
        let chosen = await withoutListings(picks.compactMap { offered.indices.contains($0 - 1) ? offered[$0 - 1] : nil })
        var result = varied(chosen, count: count)
        // Short after two a site: the rest of the picks, rather than whatever a
        // site posted last (that's how two event listings made Top stories).
        for story in chosen where result.count < count && !result.contains(where: { told($0, story) }) {
            result.append(story)
        }
        // The model picked next to nothing: the newest fill in.
        return result.count >= 3 ? result : varied(result + newest, count: count)
    }

    /// The picks less what only announces something: told to leave out event
    /// listings, the model still put a club night and a film programme on the
    /// front page, but asked just this about a handful, it spots them.
    @MainActor private static func withoutListings(_ picks: [NewsStory]) async -> [NewsStory] {
        guard !picks.isEmpty else { return picks }
        let numbered = picks.enumerated().map { "\($0.offset + 1). \($0.element.title)" }
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: """
            Some headlines report news: something that happened or was decided. Others only announce \
            something upcoming or on offer: a concert, a party, a club night, a mass, a film or theatre \
            programme, a premiere, a sale, deals. Find the ones that only announce.
            """)
        let prompt = "Headlines:\n" + numbered.joined(separator: "\n")
        guard let out = try? await session.respond(to: prompt, generating: NotNews.self).content.numbers else { return picks }
        let dropped = Set(out)
        // Wrong about most of them, it's guessing: keep them all.
        guard dropped.count * 2 <= picks.count else { return picks }
        return picks.enumerated().filter { !dropped.contains($0.offset + 1) }.map(\.element)
    }

    /// Up to `limit` stories, each site's next newest in turn.
    static func balanced(_ newest: [NewsStory], limit: Int) -> [NewsStory] {
        var bySite: [String: [NewsStory]] = [:], sites: [String] = []
        for story in newest {
            if bySite[story.host] == nil { sites.append(story.host) }
            bySite[story.host, default: []].append(story)
        }
        var result: [NewsStory] = []
        for round in 0... {
            let next = sites.compactMap { bySite[$0]?.dropFirst(round).first }
            guard !next.isEmpty else { break }
            result += next.prefix(limit - result.count)
            if result.count >= limit { break }
        }
        return result
    }

    private static func told(_ a: NewsStory, _ b: NewsStory) -> Bool {
        a.link == b.link || sameStory(a.title, b.title)
    }

    /// In order, skipping a third story from one site and any story already told.
    static func varied(_ stories: [NewsStory], count: Int, perSite limit: Int = 2) -> [NewsStory] {
        var result: [NewsStory] = []
        var perSite: [String: Int] = [:]
        for story in stories where result.count < count {
            guard perSite[story.host, default: 0] < limit,
                  !result.contains(where: { told($0, story) }) else { continue }
            result.append(story)
            perSite[story.host, default: 0] += 1
        }
        return result
    }

    /// Two headlines about one event share most of their words that matter,
    /// or two of them in a short headline: "Studenti proglasili pobjedu. Vučić
    /// priznao poraz" and "Vučić srušen na izborima, studenti pobijedili" ("pobjedu"
    /// and "pobijedili" don't meet as stems).
    static func sameStory(_ a: String, _ b: String) -> Bool {
        let left = stems(a), right = stems(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let shared = left.intersection(right).count
        let share = Double(shared) / Double(min(left.count, right.count))
        return share >= 0.5 || (shared >= 2 && share >= 0.4)
    }

    /// Words that matter, cut to a rough stem: "poginula" and "poginuo" meet as "poginu".
    private static func stems(_ text: String) -> Set<String> {
        Set(folded(text).split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.map { String($0.prefix(6)) })
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Topics

    /// Croatian news feeds topics are looked for in, besides your own
    /// sources: the national sites and the sports pages, where most of what
    /// a Croatian reader follows turns up.
    static let topicPool: [NewsSite] = NewsSite.suggestions.filter { $0.host.hasSuffix(".hr") } + [
        NewsSite(host: "jutarnji.hr", feed: URL(string: "https://www.jutarnji.hr/sportske/feed"), path: "/sportske", name: "Sportske novosti"),
        NewsSite(host: "index.hr", feed: URL(string: "https://www.index.hr/rss/sport"), path: "/sport", name: "Index Sport"),
        NewsSite(host: "glas-slavonije.hr", feed: nil, path: "/sport", page: URL(string: "https://glas-slavonije.hr/sport/"), name: "Glas Slavonije Sport"),
    ]

    /// Stories about a topic among `stories`: headlines that name it, then
    /// Apple's on-device model drops those about something else that shares
    /// the name ("Osijek" the city when it's NK Osijek you follow).
    @MainActor static func about(_ topic: String, in stories: [NewsStory], count: Int = 4) async -> [NewsStory] {
        // The topic's most telling word, cut to a stem: "Osijek" finds "Osijeka" and "Osijeku" too.
        let words = folded(topic).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let key = words.max(by: { $0.count < $1.count }) else { return [] }
        let stem = key.count > 5 ? String(key.dropLast()) : key
        let matching = varied(recent(stories, hours: 48).filter { story in
            let text = folded(story.title + " " + (story.summary ?? ""))
            return text.split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(stem) }
        }, count: 20, perSite: 20)
        guard words.count > 1 || key.count < 6, AppleModels.onDeviceAvailable, !matching.isEmpty else {
            return Array(matching.prefix(count))
        }
        let numbered = matching.enumerated().map { "\($0.offset + 1). \($0.element.title)" }
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: """
            You sort news headlines for someone who follows one subject. Keep only the headlines that are \
            about that subject itself, not about something else that shares a word with it.
            """)
        let prompt = "Subject: \(topic)\n\nHeadlines:\n" + numbered.joined(separator: "\n") + "\n\nWhich are about \(topic)?"
        guard let picks = try? await session.respond(to: prompt, generating: TopicMatch.self).content.numbers else {
            return Array(matching.prefix(count))
        }
        let kept = Set(picks)
        return Array(matching.enumerated().filter { kept.contains($0.offset + 1) }.map(\.element).prefix(count))
    }

    // MARK: Fetching

    @concurrent static func text(at url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 roko",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.quick.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data.prefix(1_200_000), encoding: .utf8) ?? String(decoding: data.prefix(1_200_000), as: UTF8.self)
    }

    private static func feedLinks(in html: String, base: URL) -> [URL] {
        let pattern = #"<link[^>]+type=["']application/(?:rss|atom)\+xml["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let tag = Range(match.range, in: html).map({ String(html[$0]) }),
                  let href = tag.firstMatch(of: /href=["']([^"']+)["']/)?.1 else { return nil }
            return URL(string: String(href).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
        }
    }

    @concurrent static func stories(from feed: URL, host: String) async -> [NewsStory]? {
        var request = URLRequest(url: feed, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone) roko", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.quick.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return await Task.detached(priority: .utility) { FeedParser.parse(data, host: host) }.value
    }
}

@Generable
nonisolated struct FrontPage {
    @Guide(description: "The numbers of the chosen headlines, most important first")
    var numbers: [Int]
}

@Generable
nonisolated struct NotNews {
    @Guide(description: "The numbers of the headlines that announce something upcoming or on offer; none if none do")
    var numbers: [Int]
}

@Generable
nonisolated struct TopicMatch {
    @Guide(description: "The numbers of the headlines about the subject; none if no headline is")
    var numbers: [Int]
}

/// Headlines from a page with no feed: the links into the page's own section
/// that read like headlines. A news card usually holds a kicker ("DOLAZI
/// RUDEŠ"), the headline and a subhead; the headline is the element named
/// for it, else an h1 to h4, else the longest piece of text in the link.
nonisolated enum PageHeadlines {
    static func parse(_ html: String, page: URL, host: String) -> [NewsStory] {
        let section = page.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var stories: [NewsStory] = []
        var seen = Set<String>()
        for match in html.matches(of: /<a\s[^>]*href=["']([^"'#]+)["'][^>]*>([\s\S]*?)<\/a>/) {
            guard let url = URL(string: decode(String(match.1)), relativeTo: page)?.absoluteURL,
                  url.host()?.hasSuffix(host) == true else { continue }
            let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Into the section, and deeper than it: an article, not the section's own menu.
            guard section.isEmpty || path.hasPrefix(section + "/"), path.count > section.count + 8,
                  seen.insert(url.absoluteString).inserted else { continue }
            guard let title = headline(in: String(match.2)), title.count >= 20, title.count <= 220 else { continue }
            stories.append(NewsStory(title: title, link: url, host: host, published: date(in: path)))
            if stories.count >= 30 { break }
        }
        return stories
    }

    private static func headline(in inner: String) -> String? {
        // An element named for the headline: …title, …head, …headline, …heading (not over- or subhead).
        for element in inner.matches(of: /<(\w+)[^>]*class=["']([^"']*)["'][^>]*>([\s\S]*?)<\/\1>/) {
            let names = String(element.2).split(separator: " ").map { $0.split(whereSeparator: { "_-".contains($0) }).last.map(String.init) ?? "" }
            if names.contains(where: { ["title", "head", "headline", "heading"].contains($0.lowercased()) }) {
                let text = plain(String(element.3))
                if text.count >= 20 { return text }
            }
        }
        if let heading = inner.firstMatch(of: /<h[1-4][^>]*>([\s\S]*?)<\/h[1-4]>/) {
            let text = plain(String(heading.1))
            if text.count >= 20 { return text }
        }
        // The longest run of text between tags.
        let pieces = inner.split(separator: "<").compactMap { $0.split(separator: ">", maxSplits: 1).last.map { plain(String($0)) } }
        return pieces.max { $0.count < $1.count }
    }

    /// A date written into the address: /2026/10/23/ or 2026-10-23.
    private static func date(in path: String) -> Date? {
        guard let match = path.firstMatch(of: /(20\d\d)[\/-](\d\d)[\/-](\d\d)/) else { return nil }
        var parts = DateComponents()
        parts.year = Int(match.1)
        parts.month = Int(match.2)
        parts.day = Int(match.3)
        parts.hour = 12
        return Calendar.current.date(from: parts)
    }

    static func plain(_ html: String) -> String {
        decode(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "&amp;", with: "&")
        guard text.contains("&") else { return text }
        for (name, character) in named { text = text.replacingOccurrences(of: name, with: character) }
        // Numbered: "iFixit&#8217;s", "&#x2019;".
        guard text.contains("&#") else { return text }
        var result = "", rest = text[...]
        while let start = rest.range(of: "&#") {
            result += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: end) <= 7 else {
                result += "&#"
                rest = after
                continue
            }
            let digits = after[..<end]
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) } else { result += "&#" + digits + ";" }
            rest = after[after.index(after: end)...]
        }
        return result + rest
    }

    private static let named: [(String, String)] = [
        ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
        ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ("&ndash;", "\u{2013}"), ("&mdash;", "\u{2014}"), ("&hellip;", "\u{2026}"),
    ]
}

/// RSS 2.0 and Atom, the two feed formats news sites use.
nonisolated final class FeedParser: NSObject, XMLParserDelegate {
    private let host: String
    private var stories: [NewsStory] = []
    private var inItem = false
    private var element = ""
    private var title = "", link = "", date = "", summary = ""

    private init(host: String) {
        self.host = host
    }

    static func parse(_ data: Data, host: String) -> [NewsStory]? {
        let delegate = FeedParser(host: host)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || !delegate.stories.isEmpty else { return nil }
        return delegate.stories
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "item" || name == "entry" {
            inItem = true
            title = ""; link = ""; date = ""; summary = ""
        } else if inItem, name == "link", let href = attributes["href"],
                  attributes["rel"] == nil || attributes["rel"] == "alternate" {
            link = href  // Atom
        }
        element = name
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard inItem, let text = String(data: block, encoding: .utf8) else { return }
        append(text)
    }

    private func append(_ text: String) {
        switch element {
        case "title": title += text
        case "link": link += text
        case "pubDate", "published", "dc:date": date += text
        case "updated": if date.isEmpty { date += text }
        case "description", "summary": if summary.count < 600 { summary += text }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" || name == "entry" {
            inItem = false
            let title = PageHeadlines.plain(title)
            if !title.isEmpty, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                let summary = PageHeadlines.plain(summary)
                stories.append(NewsStory(title: title, link: url, host: host, published: Self.date(date),
                                         summary: summary.isEmpty ? nil : String(summary.prefix(300))))
            }
        }
        element = ""
    }

    private static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"]
        .map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }

    private static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let iso = try? Date(text, strategy: .iso8601) { return iso }
        if let iso = ISO8601DateFormatter().date(from: text) { return iso }
        for formatter in rfc822 { if let date = formatter.date(from: text) { return date } }
        return nil
    }
}
