import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, kagi, brave

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        }
    }

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: "searchEngine").flatMap(SearchEngine.init) ?? .google
    }

    func searchURL(for query: String) -> URL {
        let base = switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .kagi: "https://kagi.com/search"
        case .brave: "https://search.brave.com/search"
        }
        var components = URLComponents(string: base)!
        // The page in the phone's language and for where it is, not wherever
        // the network seems to be (an English phone on a Croatian network got
        // Google in Croatian).
        components.queryItems = [URLQueryItem(name: "q", value: query)] + (self == .google ? localeItems : [])
        return components.url!
    }

    /// Autocomplete endpoint and a parser for its response.
    fileprivate var suggestions: (URL, (Data) -> [String])? {
        switch self {
        case .google:
            // client=firefox returns plain JSON: [query, [suggestion, ...]]
            return (URL(string: "https://suggestqueries.google.com/complete/search?client=firefox")!, { data in
                (try? JSONSerialization.jsonObject(with: data) as? [Any])?.dropFirst().first as? [String] ?? []
            })
        case .duckDuckGo:
            return (URL(string: "https://duckduckgo.com/ac/?type=list")!, { data in
                (try? JSONSerialization.jsonObject(with: data) as? [Any])?.dropFirst().first as? [String] ?? []
            })
        case .brave:
            return (URL(string: "https://search.brave.com/api/suggest?rich=false")!, { data in
                (try? JSONSerialization.jsonObject(with: data) as? [Any])?.dropFirst().first as? [String] ?? []
            })
        case .kagi:
            return nil
        }
    }

    /// The phone's language and region, so suggestions are for where it is
    /// and not wherever the network happens to be ("new yorker osijek").
    private var localeItems: [URLQueryItem] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier
        switch self {
        case .google: return [URLQueryItem(name: "hl", value: language)] + (region.map { [URLQueryItem(name: "gl", value: $0.lowercased())] } ?? [])
        case .duckDuckGo: return [URLQueryItem(name: "kl", value: Audience.duckDuckGoRegion)]
        case .brave, .kagi: return []
        }
    }

    func fetchSuggestions(for query: String) async -> [String] {
        guard let (endpoint, parse) = suggestions,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "q", value: query)] + localeItems
        guard let url = components.url,
              let (data, _) = try? await URLSession.quick.data(from: url) else { return [] }
        return parse(data)
    }
}

enum Omnibox {
    /// The URL the user meant, or nil when the input reads as a search.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about"].contains(scheme) {
            return url
        }
        if text.hasPrefix("localhost") || text.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + text)
        }
        // "example.com", "news.ycombinator.com/item?id=1": a dot and a plausible TLD.
        guard let url = URL(string: "https://" + text), let host = url.host(),
              let tld = host.split(separator: ".").last, host.contains("."),
              tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return url
    }

    static func destination(for input: String) -> URL {
        url(from: input) ?? SearchEngine.current.searchURL(for: input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
