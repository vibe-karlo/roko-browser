import Foundation
import FoundationModels

/// Saved pages shown together, which can be summarized as one.
nonisolated struct ReadLaterGroup: Identifiable, Equatable, Codable {
    let name: String
    let pages: [UUID]
    var id: String { pages.map(\.uuidString).joined(separator: ",") }
}

/// Why a page was put aside, rather than what it mentions: a story about a
/// furniture maker is news, a page of sofas for a small flat is for the home.
/// A fixed list: the on-device model keeps to one far better than it writes,
/// and it writes Croatian badly and mistranslates it, while it reads it well
/// enough to choose. The names are ours, so they're always plain and in the
/// app's language.
nonisolated enum SavedTopic: String, CaseIterable {
    case news, app, buy, home, recipe, trip, guide, read, work, health, money, watch, event, other

    var name: String {
        switch self {
        case .news: "News"
        case .app: "Apps"
        case .buy: "To buy"
        case .home: "For the home"
        case .recipe: "Recipes"
        case .trip: "Travel"
        case .guide: "Guides"
        case .read: "Long reads"
        case .work: "Work"
        case .health: "Health"
        case .money: "Money"
        case .watch: "To watch"
        case .event: "Events"
        case .other: "Other"
        }
    }

    /// What the model is told it means.
    fileprivate var meaning: String {
        switch self {
        case .news: "a report of what happened recently: politics, crime, sport, business, accidents"
        case .app: "an app, program or online tool to try or use"
        case .buy: "a product, shop page, price or review, to decide on buying"
        case .home: "furnishing, decorating, repairing or renovating a home"
        case .recipe: "a dish to cook or bake"
        case .trip: "a place to go, somewhere to stay, a route"
        case .guide: "how to do something: a tutorial or documentation"
        case .read: "an essay, opinion, story or explainer, to read out of interest"
        case .work: "jobs, career, running a business"
        case .health: "health, fitness, medicine"
        case .money: "one's own money: banks, taxes, loans, investing"
        case .watch: "a film, show, video, music or podcast"
        case .event: "a concert, match, exhibition or anything else on a date"
        case .other: "none of these"
        }
    }
}

/// Chooses a page's topic, once, and it's kept with the page. On this device,
/// so nothing saved leaves the phone; Claude only where a key has been set and
/// the on-device model isn't here or won't answer. Apple's cloud model isn't
/// asked: this runs without anyone asking for it.
enum SavedTopics {
    /// Whether anything can be asked at all.
    static var canAsk: Bool { AppleModels.onDeviceAvailable || ClaudeClient.configured != nil }

    /// Known from the address alone, with no model.
    static func evident(from url: URL) -> SavedTopic? {
        ["apps.apple.com", "play.google.com", "testflight.apple.com"].contains(url.host() ?? "") ? .app : nil
    }

    /// The page's topic; nil when no one could answer now, to ask again later.
    static func topic(of page: ReadLaterPage) async -> SavedTopic? {
        let prompt = """
            Title: \(page.title)
            Address: \(page.url.absoluteString.prefix(120))

            \(page.text.prefix(900))
            """
        var declined = false
        if AppleModels.onDeviceAvailable {
            do {
                return parsed(try await onDevice(prompt))
            } catch LanguageModelError.guardrailViolation, LanguageModelError.refusal {
                declined = true
            } catch {
                AITrace.log("saved topic: \(error)")
            }
        }
        if let client = ClaudeClient.configured, let answer = try? await withClaude(client, prompt: prompt) {
            return parsed(answer)
        }
        // It would only decline again.
        return declined ? .other : nil
    }

    private static let instructions = """
        Someone saved a web page to come back to it. Choose why, from this list:

        \(SavedTopic.allCases.map { "\($0.rawValue): \($0.meaning)" }.joined(separator: "\n"))

        Go by what they would come back to do, not by what the page mentions. A news story about \
        a furniture maker is news. A page about sofas for a small flat is home. An article \
        recommending which phone to get is buy. Pages may be in any language. Answer with one word \
        from the list and nothing else.
        """

    /// Plain text, not a shape to fill: Apple's permissive guardrails only apply
    /// to plain text, and news filled into a shape gets turned down. This long
    /// without an answer counts as none: a model can go quiet without failing.
    private static func onDevice(_ prompt: String) async throws -> String {
        let answer = Task {
            let session = LanguageModelSession(model: AppleModels.summarizing, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
        let watch = Task {
            try await Task.sleep(for: AppleModels.quietLimit)
            answer.cancel()
        }
        defer { watch.cancel() }
        return try await answer.value
    }

    private static func withClaude(_ client: ClaudeClient, prompt: String) async throws -> String {
        var text = ""
        for try await event in client.stream(system: instructions, prompt: prompt, model: .haiku, effort: "low", maxTokens: 20) {
            if case .text(let chunk) = event { text += chunk }
        }
        return text
    }

    /// The first word of the answer that's on the list. Nothing on it: a page that fits nothing.
    private static func parsed(_ answer: String) -> SavedTopic {
        let topic = answer.lowercased().split { !$0.isLetter }.lazy.compactMap { SavedTopic(rawValue: String($0)) }.first ?? .other
        AITrace.log("saved topic: \(answer) -> \(topic.rawValue)")
        return topic
    }
}

// MARK: Searching

nonisolated enum SavedSearch {
    /// Pages with every word somewhere, newest first: those with it in the title,
    /// site or topic ahead of those with it only in the text. Case and accents
    /// don't count, so "uhiceno" finds "uhićeno".
    static func pages(_ pages: [ReadLaterPage], matching query: String) -> [UUID] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        func hasAll(_ text: String) -> Bool { words.allSatisfy(text.localizedStandardContains) }
        var named: [UUID] = [], within: [UUID] = []
        for page in pages.sorted(by: { $0.savedAt > $1.savedAt }) {
            if hasAll("\(page.title) \(page.site) \(page.topic.name)") {
                named.append(page.id)
            } else if hasAll(page.text) {
                within.append(page.id)
            }
        }
        return named + within
    }
}

// MARK: The Saved page's groups

/// How the Saved page gathers what's still to read.
nonisolated enum SavedGrouping: String, CaseIterable {
    case topic, date

    static let key = "readLater.grouping"

    var title: String {
        switch self {
        case .topic: "Topic"
        case .date: "Date"
        }
    }
}

/// One heading and the pages under it.
nonisolated struct SavedSection: Identifiable {
    let id: String
    let name: String
    let pages: [ReadLaterPage]
    /// Pages still waiting for their topic: they have nothing in common yet.
    var isWaiting = false

    /// A summary is of what's still to read, and needs two pages with text to bring together.
    var group: ReadLaterGroup? {
        guard !isWaiting else { return nil }
        let readable = pages.filter { !$0.isRead && $0.text.count > 200 }
        return readable.count >= 2 ? ReadLaterGroup(name: name, pages: readable.map(\.id)) : nil
    }

    /// The topics with most still to read first, then the fullest. Other comes last, and a page with no topic yet shows under it, or under
    /// a heading of its own while the topics are being chosen: every page shows.
    static func byTopic(_ pages: [ReadLaterPage], sorting: Bool) -> [SavedSection] {
        let waiting = sorting ? pages.filter { $0.reason == nil } : []
        let topics = Dictionary(grouping: pages.filter { !(sorting && $0.reason == nil) }, by: \.topic)
        func newest(_ pages: [ReadLaterPage]) -> Date { pages.map(\.savedAt).max() ?? .distantPast }
        func unreadCount(_ pages: [ReadLaterPage]) -> Int { pages.filter { !$0.isRead }.count }
        var sections = topics.filter { $0.key != .other }
            .sorted { (unreadCount($0.value), $0.value.count, newest($0.value)) > (unreadCount($1.value), $1.value.count, newest($1.value)) }
            .map { SavedSection(id: $0.key.rawValue, name: $0.key.name, pages: unreadFirst($0.value)) }
        if !waiting.isEmpty {
            sections.append(SavedSection(id: "waiting", name: "Still sorting", pages: unreadFirst(waiting), isWaiting: true))
        }
        if let other = topics[.other] {
            sections.append(SavedSection(id: SavedTopic.other.rawValue, name: SavedTopic.other.name, pages: unreadFirst(other)))
        }
        return sections
    }

    /// Newest first, in spans that widen with age.
    static func byDate(_ pages: [ReadLaterPage], now: Date = .now, calendar: Calendar = .current) -> [SavedSection] {
        var sections: [(name: String, pages: [ReadLaterPage])] = []
        for page in pages.sorted(by: { $0.savedAt > $1.savedAt }) {
            let name = span(of: page.savedAt, now: now, calendar: calendar)
            if sections.last?.name == name {
                sections[sections.count - 1].pages.append(page)
            } else {
                sections.append((name, [page]))
            }
        }
        return sections.map { SavedSection(id: $0.name, name: $0.name, pages: unreadFirst($0.pages)) }
    }

    /// Newest first within each.
    private static func unreadFirst(_ pages: [ReadLaterPage]) -> [ReadLaterPage] {
        let newest = pages.sorted { $0.savedAt > $1.savedAt }
        return newest.filter { !$0.isRead } + newest.filter(\.isRead)
    }

    private static func span(of date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) || date > now { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This week" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This month" }
        // In the app's language, like the words above, whatever the phone's is.
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let month = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.wide)
        return calendar.isDate(date, equalTo: now, toGranularity: .year) ? date.formatted(month) : date.formatted(month.year())
    }
}
