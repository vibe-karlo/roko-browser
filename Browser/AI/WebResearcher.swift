import Foundation

/// The browsing half of Browse for Me when Apple's model writes the answer:
/// search, open the top results in parallel, and keep their readable text.
/// Plain HTTP and text extraction, no web views, so it is quick and light.
nonisolated enum WebResearcher {
    struct Page: Sendable {
        let url: URL
        let title: String
        let snippet: String
        var text = ""
        /// The page's share image (og:image), shown above the answer.
        var image: URL?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ","),
        ]
        return URLSession(configuration: configuration)
    }()

    // MARK: Search

    /// DuckDuckGo's lightweight HTML results: no key, no JavaScript, direct links.
    static func search(_ query: String) async throws -> [Page] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        // Results for where the phone is: with no region, DuckDuckGo guessed
        // from the address and mixed in pages from elsewhere.
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: Audience.duckDuckGoRegion)]
        let (data, _) = try await session.data(from: components.url!)
        let html = String(decoding: data, as: UTF8.self)

        let links = matches(#"class="result__a" href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: html).map { $0[0] }
        var pages: [Page] = []
        var hosts = Set<String>()
        for (index, link) in links.enumerated() {
            guard let url = URL(string: decodeEntities(link[0])), let host = url.host(),
                  !host.contains("duckduckgo.com") else { continue }  // ads route through DDG
            // One page per site, so a site with several hits doesn't crowd out the others.
            guard hosts.insert(url.displayHost).inserted else { continue }
            let snippet = index < snippets.count ? plain(snippets[index]) : ""
            pages.append(Page(url: url, title: plain(link[1]), snippet: snippet))
        }
        return pages
    }

    // MARK: Reading

    /// Fetches pages concurrently and keeps the ones with real text. `onRead`
    /// hears about each page as it finishes, so the app can show the reading live.
    static func read(_ pages: [Page], perPageLimit: Int,
                     onRead: @escaping @MainActor (_ url: URL, _ useful: Bool) -> Void = { _, _ in }) async -> [Page] {
        await withTaskGroup(of: (Int, String, URL?).self) { group in
            for (index, page) in pages.enumerated() {
                group.addTask {
                    guard let (data, response) = try? await session.data(from: page.url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          (response.mimeType ?? "").contains("html") else { return (index, "", nil) }
                    let html = String(decoding: data, as: UTF8.self)
                    return (index, articleText(html, limit: perPageLimit), shareImage(html, base: page.url))
                }
            }
            var read = pages
            for await (index, text, image) in group {
                read[index].text = text
                read[index].image = image
                await onRead(read[index].url, text.count > 300)
            }
            return read.filter { $0.text.count > 300 }
        }
    }

    /// One page's share image, read from its head alone: for answers Claude
    /// wrote from pages it read on its own servers.
    static func shareImage(of url: URL) async -> URL? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response.mimeType ?? "").contains("html") else { return nil }
        let end = Data("</head>".utf8)
        var head = Data()
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count % 8_192 == 0, head.range(of: end) != nil || head.count >= 60_000 { break }
            }
        } catch {}
        return shareImage(String(decoding: head, as: UTF8.self), base: url)
    }

    /// Pictures without repeats: the same file is often shared at several sizes
    /// ("1200px-Cathedral.jpg", "800px-Cathedral.jpg") or by sister sites.
    static func distinctImages(_ images: [URL]) -> [URL] {
        var seen: Set<String> = []
        return images.filter { url in
            let name = url.lastPathComponent.lowercased()
                .replacingOccurrences(of: #"^\d+px-"#, with: "", options: .regularExpression)
            return seen.insert(name.isEmpty ? url.absoluteString : name).inserted
        }
    }

    /// The page's og:image (or twitter:image), when it has one.
    static func shareImage(_ html: String, base: URL) -> URL? {
        let head = String(html.prefix(60_000))
        for pattern in [#"<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]+content=["']([^"']+)["']"#,
                        #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["']"#] {
            if let raw = matches(pattern, in: head).first?.first,
               let url = URL(string: decodeEntities(raw), relativeTo: base)?.absoluteURL,
               url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// Paragraph-level text from an HTML page, skipping scripts and page chrome.
    static func articleText(_ html: String, limit: Int) -> String {
        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        var paragraphs: [String] = []
        var length = 0
        for match in matches(#"<(p|li|h[1-3])\b[^>]*>([\s\S]*?)</\1>"#, in: body) {
            let text = plain(match[1])
            guard text.count >= 40 else { continue }
            paragraphs.append(text)
            length += text.count
            if length > limit { break }
        }
        return String(paragraphs.joined(separator: "\n").prefix(limit))
    }

    // MARK: Helpers

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { result in
            (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    static func plain(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'",
                                    "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#x2F;": "/"] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities: &#8217; and &#x2019;
        for match in matches(#"&#(x?)([0-9a-fA-F]+);"#, in: result).reversed() {
            let value = match[0].isEmpty ? UInt32(match[1]) : UInt32(match[1], radix: 16)
            guard let value, let scalar = Unicode.Scalar(value) else { continue }
            result = result.replacingOccurrences(of: "&#\(match[0])\(match[1]);", with: String(Character(scalar)))
        }
        return result
    }
}
