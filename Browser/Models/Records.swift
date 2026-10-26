import Foundation
import SwiftData

// Every property has a default and nothing is unique-constrained, so the same
// schema can later be mirrored to iCloud with CloudKit without a migration.

@Model
final class Pin {
    var url: String = ""
    var title: String = ""
    var order: Int = 0
    var createdAt: Date = Date.now

    init(url: URL, title: String, order: Int) {
        self.url = url.absoluteString
        self.title = title
        self.order = order
    }

    var host: String { URL(string: url)?.displayHost ?? url }
}

@Model
final class HistoryEntry {
    // The bar looks history up by address and lists it newest first.
    #Index<HistoryEntry>([\.url], [\.visitedAt])
    var url: String = ""
    var title: String = ""
    var visitedAt: Date = Date.now
    var visitCount: Int = 1

    init(url: URL, title: String) {
        self.url = url.absoluteString
        self.title = title
    }
}

@Model
final class SavedTab {
    var tabID: UUID = UUID()
    var url: String = ""
    var title: String = ""
    var order: Int = 0
    var lastActive: Date = Date.now
    var interactionState: Data?

    init(tabID: UUID, url: String, title: String, order: Int, lastActive: Date, interactionState: Data?) {
        self.tabID = tabID
        self.url = url
        self.title = title
        self.order = order
        self.lastActive = lastActive
        self.interactionState = interactionState
    }
}

/// A page roko checks for you (Notify Me), with what to look for on it.
@Model
final class Watch {
    var url: String = ""
    var title: String = ""
    /// In the person's own words; empty means anything new.
    var lookFor: String = ""
    var everyHours: Int = 24
    var createdAt: Date = Date.now
    var lastChecked: Date?
    /// The page as last read, one line per paragraph, item or offer.
    var snapshot: String = ""
    /// Its text only appears once its scripts run, so it's read in a hidden
    /// web view, which only works while roko is open.
    var needsRendering: Bool = false
    /// How the snapshot was read (`PageLines.version`): read another way, it's
    /// read afresh rather than compared, which would announce the difference
    /// in reading as news.
    var readingVersion: Int = 0
    /// The last thing it noticed, for the list in Settings.
    var lastNews: String?
    var lastNewsAt: Date?

    init(url: URL, title: String) {
        self.url = url.absoluteString
        self.title = title
    }

    var host: String { URL(string: url)?.displayHost ?? url }

    var nextCheck: Date {
        (lastChecked ?? .distantPast).addingTimeInterval(Double(everyHours) * 3600)
    }
}

nonisolated extension URL {
    /// Host without the "www." that tells the reader nothing.
    var displayHost: String {
        guard let host = host() else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
