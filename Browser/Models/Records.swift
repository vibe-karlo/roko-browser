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

nonisolated extension URL {
    /// Host without the "www." that tells the reader nothing.
    var displayHost: String {
        guard let host = host() else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
