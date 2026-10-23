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
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await session.data(from: components.url!)
        let html = String(decoding: data, as: UTF8.self)

        let links = matches(#"class="result__a" href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: html).map { $0[0] }
        var pages: [Page] = []
        for (index, link) in links.enumerated() {
            guard let url = URL(string: decodeEntities(link[0])), let host = url.host(),
                  !host.contains("duckduckgo.com") else { continue }  // ads route through DDG
            let snippet = index < snippets.count ? plain(snippets[index]) : ""
            pages.append(Page(url: url, title: plain(link[1]), snippet: snippet))
        }
        return pages
    }

    // MARK: Reading

    /// Fetches pages concurrently and keeps the ones with real text.
    static func read(_ pages: [Page], perPageLimit: Int) async -> [Page] {
        await withTaskGroup(of: (Int, String).self) { group in
            for (index, page) in pages.enumerated() {
                group.addTask {
                    guard let (data, response) = try? await session.data(from: page.url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          (response.mimeType ?? "").contains("html") else { return (index, "") }
                    return (index, articleText(String(decoding: data, as: UTF8.self), limit: perPageLimit))
                }
            }
            var read = pages
            for await (index, text) in group { read[index].text = text }
            return read.filter { $0.text.count > 300 }
        }
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

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { result in
            (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    private static func plain(_ html: String) -> String {
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
