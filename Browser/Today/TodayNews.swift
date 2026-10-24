import Foundation
import FoundationModels

/// A news site you chose for Today, with its feed once found.
nonisolated struct NewsSite: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// What it's called on the page: its host, "index.hr".
    var host: String
    var feed: URL?
    var id: String { host }

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

    // MARK: Chosen sites

    static let key = "today.newsSites"

    static var chosen: [NewsSite] {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([NewsSite].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

/// One story from a site's feed.
nonisolated struct NewsStory: Codable, Equatable, Hashable, Identifiable, Sendable {
    let title: String
    let link: URL
    let host: String
    let published: Date?
    var id: URL { link }
}

/// Reads the chosen sites' feeds (RSS or Atom), and has Apple's on-device
/// model pick the day's most important stories from them. It only picks: the
/// headlines stay in the sites' own words, so nothing is lost in translation
/// and nothing is paid for.
enum TodayNews {
    /// Finds a site's feed from its address: the one its homepage names, or
    /// the usual places a feed lives.
    static func findFeed(for address: String) async -> NewsSite? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let home = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), let host = home.host() else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let known = NewsSite.suggestions.first(where: { $0.host == name }) { return known }
        var candidates: [URL] = []
        if let html = await text(at: home) {
            candidates += feedLinks(in: html, base: home)
        }
        // The ones the homepage names first, then the usual places.
        candidates += ["feed", "rss", "rss.xml", "feed.xml", "index.xml", "feeds/posts/default"]
            .compactMap { URL(string: "/" + $0, relativeTo: home)?.absoluteURL }
        for candidate in candidates {
            if let stories = await stories(from: candidate, host: name), !stories.isEmpty {
                return NewsSite(host: name, feed: candidate)
            }
        }
        return nil
    }

    /// The newest stories of every chosen site, from the last day and a half.
    static func latest(from sites: [NewsSite]) async -> [NewsStory] {
        await withTaskGroup(of: [NewsStory].self) { group in
            for site in sites {
                guard let feed = site.feed else { continue }
                group.addTask { await stories(from: feed, host: site.host) ?? [] }
            }
            var all: [NewsStory] = []
            for await stories in group {
                let recent = stories.filter { ($0.published ?? .now) > .now.addingTimeInterval(-36 * 3600) }
                all += Array((recent.isEmpty ? stories : recent).prefix(15))
            }
            return all
        }
    }

    /// The day's most important stories, picked by Apple's on-device model.
    /// Without the model (or if it fails), each site's newest. Either way, at
    /// most two from one site, and never the same story twice: the small
    /// model was asked not to and still picked one crash from two sites.
    static func top(_ stories: [NewsStory], count: Int = 6) async -> [NewsStory] {
        let newest = stories.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        guard AppleModels.onDeviceAvailable, stories.count > count else { return varied(newest, count: count) }
        let offered = Array(stories.prefix(60))
        let numbered = offered.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.host))" }
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: """
            You are an editor choosing a front page. From today's headlines, pick the stories that matter \
            most to a general reader: big national and world news, things that affect daily life. Not \
            gossip, quizzes, horoscopes, promotions, product demos or minor sport.
            """)
        let prompt = "Headlines:\n" + numbered.joined(separator: "\n") + "\n\nPick the \(count + 4) most important."
        guard let picks = try? await session.respond(to: prompt, generating: FrontPage.self).content.numbers else {
            return varied(newest, count: count)
        }
        let chosen = picks.compactMap { offered.indices.contains($0 - 1) ? offered[$0 - 1] : nil }
        // Short of picks after the rules, the newest fill in.
        return varied(chosen + newest, count: count)
    }

    /// In order, skipping a third story from one site and any story already told.
    private static func varied(_ stories: [NewsStory], count: Int) -> [NewsStory] {
        var result: [NewsStory] = []
        var perSite: [String: Int] = [:]
        for story in stories where result.count < count {
            guard perSite[story.host, default: 0] < 2,
                  !result.contains(where: { $0.link == story.link || sameStory($0.title, story.title) }) else { continue }
            result.append(story)
            perSite[story.host, default: 0] += 1
        }
        return result
    }

    /// Two headlines about one event share most of their words that matter.
    private static func sameStory(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 }
                .map { String($0.prefix(6)) })  // a rough stem: "poginula", "poginuo"
        }
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count)) >= 0.5
    }

    // MARK: Feeds

    private static func text(at url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone) roko", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data.prefix(800_000), encoding: .utf8) ?? String(decoding: data.prefix(800_000), as: UTF8.self)
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

    static func stories(from feed: URL, host: String) async -> [NewsStory]? {
        var request = URLRequest(url: feed, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone) roko", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return await Task.detached(priority: .utility) { FeedParser.parse(data, host: host) }.value
    }
}

@Generable
nonisolated struct FrontPage {
    @Guide(description: "The numbers of the chosen headlines, most important first")
    var numbers: [Int]
}

/// RSS 2.0 and Atom, the two feed formats news sites use.
nonisolated final class FeedParser: NSObject, XMLParserDelegate {
    private let host: String
    private var stories: [NewsStory] = []
    private var inItem = false
    private var element = ""
    private var title = "", link = "", date = ""

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
            title = ""; link = ""; date = ""
        } else if inItem, name == "link", let href = attributes["href"],
                  attributes["rel"] == nil || attributes["rel"] == "alternate" {
            link = href  // Atom
        }
        element = name
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch element {
        case "title": title += string
        case "link": link += string
        case "pubDate", "published", "updated", "dc:date": if date.isEmpty || element != "updated" { date += string }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard inItem, element == "title" || element == "link", let text = String(data: block, encoding: .utf8) else { return }
        if element == "title" { title += text } else { link += text }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" || name == "entry" {
            inItem = false
            let title = Self.clean(title)
            if !title.isEmpty, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                stories.append(NewsStory(title: title, link: url, host: host, published: Self.date(date)))
            }
        }
        element = ""
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
