import Foundation

/// One you added yourself in Settings: a name and an address with %s where the words go.
struct CustomSearchEngine: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var template: String

    private static let key = "searchEngines.custom"

    static var all: [CustomSearchEngine] {
        get {
            UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([CustomSearchEngine].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    /// The address as typed, made usable; nil if searching it couldn't work.
    /// Other browsers' {searchTerms} and %@ are taken too.
    static func template(from typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        for other in ["{searchTerms}", "%@"] { text = text.replacingOccurrences(of: other, with: "%s") }
        guard text.contains("%s") else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text.replacingOccurrences(of: "%s", with: "roko")), url.host()?.contains(".") == true else { return nil }
        return text
    }

    func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let words = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: words))
    }
}

enum SearchEngine: Hashable, Identifiable, RawRepresentable {
    case google, duckDuckGo, kagi, brave, qwant
    case custom(CustomSearchEngine)

    /// The ones roko comes with. Yours are in CustomSearchEngine.all.
    static let builtIn: [SearchEngine] = [.google, .duckDuckGo, .kagi, .brave, .qwant]

    var rawValue: String {
        switch self {
        case .google: "google"
        case .duckDuckGo: "duckDuckGo"
        case .kagi: "kagi"
        case .brave: "brave"
        case .qwant: "qwant"
        case .custom(let engine): "custom:\(engine.id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix("custom:") {
            guard let engine = CustomSearchEngine.all.first(where: { rawValue.hasSuffix($0.id.uuidString) }) else { return nil }
            self = .custom(engine)
        } else if let engine = Self.builtIn.first(where: { $0.rawValue == rawValue }) {
            self = engine
        } else {
            return nil
        }
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        case .qwant: "Qwant"
        case .custom(let engine): engine.name
        }
    }

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: "searchEngine").flatMap(SearchEngine.init) ?? .google
    }

    func searchURL(for query: String) -> URL {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .kagi: base = "https://kagi.com/search"
        case .brave: base = "https://search.brave.com/search"
        case .qwant: base = "https://www.qwant.com/"
        case .custom(let engine):
            // Its address was checked when added; words it still can't take go to Google.
            return engine.searchURL(for: query) ?? SearchEngine.google.searchURL(for: query)
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
        case .qwant:
            return (URL(string: "https://api.qwant.com/api/suggest/?client=opensearch")!, { data in
                (try? JSONSerialization.jsonObject(with: data) as? [Any])?.dropFirst().first as? [String] ?? []
            })
        case .kagi, .custom:
            return nil
        }
    }

    /// Whether what you type is sent to it for suggestions.
    var suggests: Bool { suggestions != nil }

    /// The phone's language and region, so suggestions are for where it is
    /// and not wherever the network happens to be ("new yorker osijek").
    private var localeItems: [URLQueryItem] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier
        switch self {
        case .google: return [URLQueryItem(name: "hl", value: language)] + (region.map { [URLQueryItem(name: "gl", value: $0.lowercased())] } ?? [])
        case .duckDuckGo: return [URLQueryItem(name: "kl", value: Audience.duckDuckGoRegion)]
        case .brave, .kagi, .qwant, .custom: return []
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
