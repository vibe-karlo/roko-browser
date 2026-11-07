import Foundation

/// One of roko's own screens you had open, as a card in the tab switcher beside your tabs:
/// To-do, News, Shopping, Saved, or a Browse for Me answer. It's a few lines of text from the
/// screen as you left it, never a picture or a screen kept alive: a few hundred bytes, and
/// opening it opens the screen again from what that screen keeps anyway.
nonisolated struct RecentScreen: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case todos, feed, shopping, readLater, answer

        var name: String {
            switch self {
            case .todos: "To-do"
            case .feed: "News"
            case .shopping: "Shopping"
            case .readLater: "Saved"
            case .answer: "Browse for Me"
            }
        }
    }

    let id: UUID
    let kind: Kind
    var usedAt: Date
    /// The screen's name, or an answer's question.
    var title: String
    var lines: [String]
}

/// The cards, newest first. Read the first time a screen closes or the switcher opens, never at launch.
@MainActor @Observable
final class RecentScreens {
    static let shared = RecentScreens()

    private(set) var items: [RecentScreen] = []

    /// A card nobody came back to in a week goes.
    static let keepFor: TimeInterval = 7 * 24 * 3600
    /// Answers kept at most; each has a small file (RecentAnswers).
    static let answerLimit = 5
    private static let key = "recentScreens"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([RecentScreen].self, from: data) {
            items = saved.filter { $0.usedAt > .now - Self.keepFor }
        }
        // Answers whose cards are gone, a Close All not taken back among them.
        RecentAnswers.sweep(keeping: Set(items.filter { $0.kind == .answer }.map(\.id)))
    }

    /// A screen was left: its card moves to the front with what it showed.
    func left(_ kind: RecentScreen.Kind, title: String, lines: [String], id: UUID? = nil) {
        let existing = items.first { kind == .answer ? $0.id == id : $0.kind == kind }
        var item = existing ?? RecentScreen(id: id ?? UUID(), kind: kind, usedAt: .now, title: title, lines: lines)
        item.usedAt = .now
        item.title = title
        item.lines = lines
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        for old in items.filter({ $0.kind == .answer }).dropFirst(Self.answerLimit) { remove(old.id, saving: false) }
        save()
    }

    /// Thrown away in the switcher. An answer's file goes with it.
    func remove(_ id: UUID, saving: Bool = true) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        if item.kind == .answer { RecentAnswers.delete(id) }
        if saving { save() }
    }

    /// Close All: every card, kept for Undo with their files.
    func takeAll() -> [RecentScreen] {
        let all = items
        items = []
        save()
        return all
    }

    func restore(_ screens: [RecentScreen]) {
        let ids = Set(items.map(\.id))
        items = (items + screens.filter { !ids.contains($0.id) }).sorted { $0.usedAt > $1.usedAt }
        save()
    }

    /// History cleared: answers asked in that time go too.
    func forgetAnswers(since: Date) {
        for item in items where item.kind == .answer && item.usedAt >= since { remove(item.id, saving: false) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// A Browse for Me answer as it was when it was closed: its questions, answers and sources.
nonisolated struct SavedAnswer: Codable, Sendable {
    struct Turn: Codable, Sendable {
        let query: String
        let text: String
        let engine: String
        let sources: [SavedSource]
        let images: [URL]
    }

    struct SavedSource: Codable, Sendable {
        let url: URL
        let title: String
    }

    let turns: [Turn]
}

/// Finished answers on disk, one small file each, in Application Support: not backed up, not synced.
nonisolated enum RecentAnswers {
    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Answers", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path()) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = url
            try? folder.setResourceValues(values)
        }
        return url
    }

    private static func file(_ id: UUID) -> URL { folder.appending(path: id.uuidString + ".json") }

    /// Written off the main thread: closing the answer doesn't wait for it.
    static func save(_ answer: SavedAnswer, id: UUID) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(answer) else { return }
            try? data.write(to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Read as the card is opened: a few kilobytes.
    static func load(_ id: UUID) -> SavedAnswer? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(SavedAnswer.self, from: data)
    }

    static func delete(_ id: UUID) {
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: file(id)) }
    }

    /// Files of no card. Only ones over an hour old: one written just now may be for a card
    /// still being made.
    static func sweep(keeping ids: Set<UUID>) {
        Task.detached(priority: .background) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path())) ?? []
            for name in names {
                guard let id = UUID(uuidString: String(name.dropLast(5))), !ids.contains(id) else { continue }
                let made = (try? file(id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
                if made < .now - 3600 { try? FileManager.default.removeItem(at: file(id)) }
            }
        }
    }
}

extension RecentScreen.Kind {
    /// The screens that get a card. Today isn't one: it comes by itself each morning.
    @MainActor init?(_ panel: BrowserModel.Panel) {
        switch panel {
        case .todos: self = .todos
        case .feed: self = .feed
        case .shopping: self = .shopping
        case .readLater: self = .readLater
        default: return nil
        }
    }
}
