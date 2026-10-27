import Foundation

/// Videos for Browse for Me: found with the same request YouTube's own search
/// box makes, and read from what each video says about itself (its description,
/// where recipes, steps and chapters usually are). No key and no account.
///
/// Transcripts aren't read: YouTube now serves them only to its own player,
/// with a token its page script makes, and roko doesn't imitate that.
nonisolated enum YouTube {
    struct Video: Sendable, Identifiable, Hashable {
        let id: String
        let title: String
        let channel: String
        /// As YouTube writes it: "8:51", "1:02:10".
        let length: String
        let seconds: Int
        /// Short form: "41K views".
        let views: String
        /// "2 weeks ago".
        let age: String
        /// The description, without its links and plugs.
        var notes = ""

        var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
        /// 320 × 180, the size the row shows it at on a 3× screen.
        var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
    }

    /// The version YouTube's web page reports for itself; requests carry it as the page's do.
    private static let clientVersion = "2.20261026.01.00"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
        ]
        return URLSession(configuration: configuration)
    }()

    private static func request(_ endpoint: String, _ body: [String: Any], language: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var client: [String: Any] = ["clientName": "WEB", "clientVersion": clientVersion, "hl": language]
        if let region = Locale.current.region?.identifier { client["gl"] = region }
        var payload = body
        payload["context"] = ["client": client]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// The top videos for a question, in YouTube's order: a minute to forty-five
    /// long (no Shorts, no streams, no hour-long podcasts).
    static func search(_ query: String, language: String, limit: Int = 4) async -> [Video] {
        // "EgIQAQ==": videos only, as the search page's Videos filter asks.
        let request = request("search", ["query": query, "params": "EgIQAQ=="], language: language)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var videos: [Video] = []
        collect(json, into: &videos, limit: limit)
        return videos
    }

    private static func collect(_ node: Any, into videos: inout [Video], limit: Int) {
        guard videos.count < limit else { return }
        if let object = node as? [String: Any] {
            if let renderer = object["videoRenderer"] as? [String: Any] {
                if let video = video(renderer), !videos.contains(where: { $0.id == video.id }) { videos.append(video) }
                return
            }
            for value in object.values { collect(value, into: &videos, limit: limit) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &videos, limit: limit) }
        }
    }

    private static func video(_ renderer: [String: Any]) -> Video? {
        func text(_ key: String) -> String {
            guard let field = renderer[key] as? [String: Any] else { return "" }
            if let simple = field["simpleText"] as? String { return simple }
            return (field["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        }
        guard let id = renderer["videoId"] as? String else { return nil }
        let length = text("lengthText")
        let seconds = length.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        guard (60...45 * 60).contains(seconds) else { return nil }
        let title = text("title")
        guard !title.isEmpty else { return nil }
        let views = text("shortViewCountText")
        return Video(id: id, title: title, channel: text("ownerText"), length: length, seconds: seconds,
                     views: views.isEmpty ? text("viewCountText") : views, age: text("publishedTimeText"))
    }

    /// Each video's description, read in parallel (about 10 KB each).
    static func describe(_ videos: [Video], language: String) async -> [Video] {
        await withTaskGroup(of: (Int, String).self) { group in
            for (index, video) in videos.enumerated() {
                group.addTask {
                    let request = request("player", ["videoId": video.id], language: language)
                    guard let (data, _) = try? await session.data(for: request),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let details = json["videoDetails"] as? [String: Any],
                          let description = details["shortDescription"] as? String else { return (index, "") }
                    return (index, notes(description))
                }
            }
            var described = videos
            for await (index, notes) in group { described[index].notes = notes }
            return described
        }
    }

    /// A description without what isn't about the video: lines that are links,
    /// hashtags, or the channel's plugs ("subscribe", "merch", "sponsored by").
    static func notes(_ description: String) -> String {
        let plugs = ["subscribe", "merch", "patreon", "sponsor", "affiliate", "instagram", "tiktok", "twitter",
                     "facebook", "discount code", "use code", "shop", "newsletter", "follow us", "follow me"]
        return description.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let lower = line.lowercased()
                return !lower.contains("http") && !lower.hasPrefix("#") && !plugs.contains(where: lower.contains)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2_500)
            .description
    }
}
