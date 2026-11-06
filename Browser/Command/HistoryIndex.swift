import Foundation
import Observation
import SwiftData

/// The bar's own view of history: the newest few thousand pages, in memory,
/// searched on every keystroke without a trip to the store. A search in the
/// store (`localizedStandardContains` on title and address) has to read every
/// row and can't use an index, so it grew with history; this scans a few
/// thousand folded strings, about a millisecond. Built off the main thread
/// after launch and again on coming back to the app; a visit updates it in place.
@MainActor @Observable
final class HistoryIndex {
    nonisolated struct Hit: Sendable {
        let url: String
        let title: String
        let visitCount: Int
        let visitedAt: Date
        /// Title and address with case and accents folded, for matching.
        let folded: String
        /// How much this page is yours: how often you open it, and how lately.
        let use: Double

        init(url: String, title: String, visitCount: Int, visitedAt: Date) {
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.visitedAt = visitedAt
            folded = HistoryIndex.fold(title + " " + url)
            use = HistoryIndex.use(visits: visitCount, at: visitedAt)
        }
    }

    /// Visits, counting for less the longer ago the last one was: a page opened often this
    /// week beats one opened as often last year. Only the last visit's date is kept.
    nonisolated static func use(visits: Int, at date: Date) -> Double {
        let days = Date.now.timeIntervalSince(date) / 86_400
        let lately = days < 4 ? 1 : days < 14 ? 0.7 : days < 31 ? 0.5 : days < 90 ? 0.3 : 0.1
        return Double(visits) * lately
    }

    /// `use` as points on the bar's scale: the first visits count most. A page opened once
    /// today is 4, twenty-five times is 20, a hundred times is 40.
    nonisolated static func points(_ use: Double, atMost cap: Int) -> Int {
        min(cap, Int(use.squareRoot() * 4))
    }

    /// Newest first.
    private(set) var hits: [Hit] = []
    /// Built at least once: before that, the bar asks the store.
    private(set) var isReady = false
    @ObservationIgnored private var building = false
    @ObservationIgnored private var builtAt = Date.distantPast
    nonisolated static let limit = 5000

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The pages you use most that match, or the newest with nothing typed. Every match is
    /// looked at, so a page you often open isn't lost behind newer ones that also match.
    func search(_ query: String, limit: Int) -> [Hit] {
        if query.isEmpty { return Array(hits.prefix(limit)) }
        let needle = Self.fold(query)
        return Array(hits.filter { $0.folded.contains(needle) }.sorted { $0.use > $1.use }.prefix(limit))
    }

    /// The pages you use most, for a bar with nothing typed in it yet.
    func mostUsed(limit: Int) -> [Hit] {
        Array(hits.sorted { $0.use > $1.use }.prefix(limit))
    }

    /// Gone now: the list is rebuilt from here at once, before a fresh read could finish.
    func remove(urls: Set<String>) {
        hits.removeAll { urls.contains($0.url) }
    }

    /// A page just visited: to the front.
    func note(url: String, title: String, visitCount: Int, visitedAt: Date) {
        hits.removeAll { $0.url == url }
        hits.insert(Hit(url: url, title: title, visitCount: visitCount, visitedAt: visitedAt), at: 0)
        if hits.count > Self.limit { hits.removeLast(hits.count - Self.limit) }
    }

    /// Reads the store again, off the main thread. With `ifOlderThan`, not
    /// when it was built within that long (coming back to the app).
    func rebuild(from container: ModelContainer, ifOlderThan age: TimeInterval = 0) {
        guard !building, Date.now.timeIntervalSince(builtAt) >= age else { return }
        building = true
        Task {
            let limit = Self.limit
            let fresh = await Task.detached(priority: .utility) { () -> [Hit] in
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.visitedAt, order: .reverse)])
                descriptor.fetchLimit = limit
                return ((try? context.fetch(descriptor)) ?? []).map {
                    Hit(url: $0.url, title: $0.title, visitCount: $0.visitCount, visitedAt: $0.visitedAt)
                }
            }.value
            hits = fresh
            isReady = true
            builtAt = .now
            building = false
            LaunchClock.mark("historyIndexed \(fresh.count)")
        }
    }
}
