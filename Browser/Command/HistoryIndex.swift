import Foundation
import SwiftData

/// The bar's own view of history: the newest few thousand pages, in memory,
/// searched on every keystroke without a trip to the store. A search in the
/// store (`localizedStandardContains` on title and address) has to read every
/// row and can't use an index, so it grew with history; this scans a few
/// thousand folded strings, about a millisecond. Built off the main thread
/// after launch and again on coming back to the app; a visit updates it in place.
@MainActor
final class HistoryIndex {
    nonisolated struct Hit: Sendable {
        let url: String
        let title: String
        let visitCount: Int
        let visitedAt: Date
        /// Title and address with case and accents folded, for matching.
        let folded: String

        init(url: String, title: String, visitCount: Int, visitedAt: Date) {
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.visitedAt = visitedAt
            folded = HistoryIndex.fold(title + " " + url)
        }
    }

    /// Newest first.
    private(set) var hits: [Hit] = []
    /// Built at least once: before that, the bar asks the store.
    private(set) var isReady = false
    private var building = false
    private var builtAt = Date.distantPast
    nonisolated static let limit = 5000

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    func search(_ query: String, limit: Int) -> [Hit] {
        if query.isEmpty { return Array(hits.prefix(limit)) }
        let needle = Self.fold(query)
        var found: [Hit] = []
        for hit in hits where hit.folded.contains(needle) {
            found.append(hit)
            if found.count == limit { break }
        }
        return found
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
