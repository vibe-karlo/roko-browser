import Foundation

/// The ways to follow a site beyond a feed it declares: the feed a platform
/// keeps at a known address, what a page says about itself for search engines,
/// and its sitemap. Each is tried only when the one before finds nothing.
nonisolated enum SiteRoutes {
    // MARK: Platforms

    /// Feeds platforms keep at known addresses but rarely link to.
    static func platformFeed(for url: URL) -> URL? {
        guard let host = url.host()?.lowercased() else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        if host.hasSuffix("reddit.com"), parts.count >= 2, parts[0] == "r" {
            return URL(string: "https://www.reddit.com/r/\(parts[1])/.rss")
        }
        if host == "github.com", parts.count >= 2 {
            return URL(string: "https://github.com/\(parts[0])/\(parts[1])/releases.atom")
        }
        if host == "bsky.app", parts.count >= 2, parts[0] == "profile" {
            return URL(string: "https://bsky.app/profile/\(parts[1])/rss")
        }
        // Mastodon and its kin: any server, an "@name" address.
        if parts.count == 1, parts[0].hasPrefix("@"), host != "www.youtube.com", host != "youtube.com" {
            return URL(string: "https://\(host)/\(parts[0]).rss")
        }
        return nil
    }

    /// Sites whose feed is declared under an address unlike the page's own, so
    /// a section's feed can't be told by its path: a YouTube channel's.
    static func declaresFeedElsewhere(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    // MARK: What a page says about itself

    /// Stories from the page's structured data (JSON-LD), which many sites
    /// built from scripts carry in full when their links aren't in the page yet.
    static func structuredStories(in html: String, page: URL, host: String) -> [NewsStory] {
        var stories: [NewsStory] = []
        var seen = Set<URL>()
        for match in html.matches(of: /<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/) {
            guard let data = String(match.1).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            collect(json, page: page, host: host, into: &stories, seen: &seen)
        }
        return Array(stories.prefix(30))
    }

    private static func collect(_ json: Any, page: URL, host: String, into stories: inout [NewsStory], seen: inout Set<URL>) {
        if let list = json as? [Any] {
            for item in list { collect(item, page: page, host: host, into: &stories, seen: &seen) }
            return
        }
        guard let object = json as? [String: Any] else { return }
        if let story = story(from: object, page: page, host: host), seen.insert(story.link).inserted {
            stories.append(story)
        }
        for value in object.values where value is [Any] || value is [String: Any] {
            collect(value, page: page, host: host, into: &stories, seen: &seen)
        }
    }

    private static func story(from object: [String: Any], page: URL, host: String) -> NewsStory? {
        guard let title = object["headline"] as? String,
              let address = (object["url"] as? String) ?? (object["mainEntityOfPage"] as? String),
              let link = URL(string: address, relativeTo: page)?.absoluteURL,
              link.host()?.hasSuffix(host) == true, link.path() != page.path() else { return nil }
        let plain = PageHeadlines.plain(title)
        guard plain.count >= 12 else { return nil }
        let date = (object["datePublished"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        let image = (object["image"] as? String) ?? ((object["image"] as? [String: Any])?["url"] as? String)
        var story = NewsStory(title: plain, link: link, host: host, published: date)
        story.image = image.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
        return story
    }

    /// A page's stories, whichever way it gives them.
    static func stories(in html: String, page: URL, host: String) -> [NewsStory] {
        let structured = structuredStories(in: html, page: page, host: host)
        if structured.count >= 3 { return structured }
        let parsed = PageHeadlines.parse(html, page: page, host: host).filter { !looksBroken($0.title) }
        // A section's links are its stories. A home page's are as much its menu:
        // Reuters' "Israel and Hamas at War", Nike's "Dispatch and Delivery".
        return page.path(percentEncoded: false).count > 1 ? parsed : parsed.filter { looksLikeStory($0.link) }
    }

    /// A headline that's really the page's code, from a link holding a picture or a style.
    private static func looksBroken(_ title: String) -> Bool {
        title.contains("{") || title.contains("src=") || title.contains("css-")
    }

    /// An address written for one story: words run together, or a number.
    private static func looksLikeStory(_ link: URL) -> Bool {
        let last = link.lastPathComponent
        return last.filter { $0 == "-" }.count >= 3 || last.contains { $0.isNumber } && last.count >= 8
    }

    // MARK: Sitemaps

    private static let storyPaths = ["news", "blog", "blogs", "posts", "post", "articles", "article", "press", "newsroom", "vijesti", "stories", "updates"]
    /// A sitemap's newest this many are looked at, and this many given their real titles.
    private static let newest = 30, titled = 12

    /// A sitemap to follow a site by: the one robots.txt names that lists enough
    /// dated stories. For a site with no feed and nothing to read in its page.
    @concurrent static func sitemap(for url: URL, path: String?) async -> URL? {
        guard let origin = URL(string: "/robots.txt", relativeTo: url)?.absoluteURL,
              let robots = await TodayNews.text(at: origin) else { return nil }
        let named = robots.matches(of: /(?im)^sitemap:\s*(\S+)/).compactMap { URL(string: String($0.1)) }
        // A news sitemap first: it's the one with today's stories in it.
        let ordered = named.sorted { $0.absoluteString.lowercased().contains("news") && !$1.absoluteString.lowercased().contains("news") }
        for map in ordered.prefix(3) {
            if await stories(fromSitemap: map, host: url.host()?.lowercased() ?? "", path: path).count >= 3 { return map }
        }
        return nil
    }

    /// The newest stories a sitemap lists, under `path` if it's for a section.
    @concurrent static func stories(fromSitemap map: URL, host: String, path: String?) async -> [NewsStory] {
        guard let xml = await TodayNews.text(at: map) else { return [] }
        var entries = parse(xml)
        // An index of sitemaps: those that sound like stories, at most three.
        if xml.contains("<sitemapindex") {
            let children = entries.map(\.loc).filter { child in
                let name = child.lowercased()
                return storyPaths.contains { name.contains($0) } || path.map { name.contains($0.lowercased()) } == true
            }
            entries = []
            for child in children.prefix(3) {
                if let url = URL(string: child), let more = await TodayNews.text(at: url) { entries += parse(more) }
            }
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let wanted = entries.filter { entry in
            guard let url = URL(string: entry.loc) else { return false }
            let parts = url.path(percentEncoded: false).split(separator: "/").map { $0.lowercased() }
            guard parts.count >= 2 else { return false }
            if let path { return url.path(percentEncoded: false).hasPrefix(path + "/") }
            return entry.title != nil || parts.dropLast().contains { storyPaths.contains($0) }
        }
        let recent = wanted.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(newest)
        // Only what has a date can be told new.
        guard recent.contains(where: { $0.date != nil }) else { return [] }
        var titles: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for entry in recent.prefix(titled) where entry.title == nil {
                group.addTask {
                    guard let url = URL(string: entry.loc), let html = await TodayNews.text(at: url) else { return (entry.loc, nil) }
                    return (entry.loc, pageTitle(html))
                }
            }
            for await (loc, title) in group { titles[loc] = title }
        }
        return recent.compactMap { entry in
            guard let url = URL(string: entry.loc) else { return nil }
            let title = entry.title ?? titles[entry.loc] ?? headline(fromSlug: url.lastPathComponent)
            return NewsStory(title: title, link: url, host: bare, published: entry.date)
        }
    }

    private struct Entry: Sendable {
        let loc: String
        let date: Date?
        let title: String?
    }

    private static func parse(_ xml: String) -> [Entry] {
        xml.matches(of: /<(?:url|sitemap)>([\s\S]*?)<\/(?:url|sitemap)>/).compactMap { match in
            let block = String(match.1)
            guard let loc = block.firstMatch(of: /<loc>\s*([^<\s]+)/)?.1 else { return nil }
            let date = block.firstMatch(of: /<(?:lastmod|news:publication_date)>\s*([^<\s]+)/).flatMap { found -> Date? in
                let text = String(found.1)
                return (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: .iso8601.year().month().day()))
            }
            let title = block.firstMatch(of: /<news:title>([\s\S]*?)<\/news:title>/).map { found in
                PageHeadlines.plain(String(found.1).replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: ""))
            }
            return Entry(loc: PageHeadlines.decode(String(loc)), date: date, title: title)
        }
    }

    private static func pageTitle(_ html: String) -> String? {
        guard let raw = html.firstMatch(of: /<title[^>]*>([^<]*)<\/title>/)?.1 else { return nil }
        let title = PageHeadlines.plain(String(raw)).split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return title?.isEmpty == false ? title : nil
    }

    /// "what-we-learned-at-scale" → "What we learned at scale".
    private static func headline(fromSlug slug: String) -> String {
        let words = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: A topic across the web

    /// Stories about a topic anywhere on the web, from Bing's news search: the
    /// one that covers Croatian sites (Google News has no Croatian edition).
    /// Bing sees the topic, not who's asking: nothing here carries a cookie.
    @concurrent static func search(_ topic: String) async -> [NewsStory] {
        var parts = URLComponents(string: "https://www.bing.com/news/search")
        let (language, country) = await Audience.isCroatian ? ("hr", "hr") : (Locale.current.language.languageCode?.identifier ?? "en", Locale.current.region?.identifier.lowercased() ?? "us")
        parts?.queryItems = [.init(name: "format", value: "rss"), .init(name: "q", value: "\"\(topic)\""),
                             .init(name: "setlang", value: language), .init(name: "cc", value: country)]
        guard let url = parts?.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        // Only a desktop browser is given the feed; a phone gets a web page.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.quick.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let found = FeedParser.parse(data, host: "bing.com", keepingBodies: true) else { return [] }
        return found.compactMap { story in
            // Each link goes through Bing, with the article's address inside it.
            guard let inner = URLComponents(url: story.link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                  let link = URL(string: inner), let rawHost = link.host()?.lowercased() else { return nil }
            var result = NewsStory(title: story.title, link: link,
                                   host: rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost,
                                   published: story.published, summary: story.summary)
            result.image = story.image
            return result
        }
    }
}
