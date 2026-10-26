import AppIntents
import Foundation
import WidgetKit

/// What the Home Screen widgets show, written by the app into the App Group
/// they share: the to-dos due by tomorrow and the weather. The widgets can't
/// read roko's store, so the app hands them this small copy whenever either
/// changes.
nonisolated struct WidgetSnapshot: Codable, Equatable {
    nonisolated struct Item: Codable, Equatable, Identifiable {
        /// Stable across saves: when the to-do was made.
        let id: String
        let title: String
        /// The day it's for, at its start. Due on that day and after.
        let day: Date
        let time: Date?
    }

    nonisolated struct Weather: Codable, Equatable {
        let temperature: Double
        let condition: String
        /// A phosphor wx-* name, as in the app.
        let glyph: String
        let high: Double
        let low: Double
        let rainChance: Int
        let place: String?
        let fetchedAt: Date
    }

    /// A pinned answer from the bar (the weather somewhere, a rate, days
    /// until, what's next), as the bar last worked it out.
    nonisolated struct Answer: Codable, Equatable, Identifiable {
        /// What was pinned: "weather in London", "100 eur in usd".
        let id: String
        let title: String
        let subtitle: String
        /// An image in the widgets' catalog: "phosphor/wx-rain", "phosphor/equals".
        let icon: String?
        let updated: Date
    }

    /// In the list's own order, due ones first.
    var items: [Item]
    /// Done today, for "3 done today".
    var doneToday: Int
    var weather: Weather?
    /// Optional: files written before answers came along have none.
    var answers: [Answer]?

    static let group = "group.com.growthstudio.roko"

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("widgets.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes it; true when it changed, so widgets reload only then.
    @discardableResult
    func save() -> Bool {
        guard let file = Self.file, Self.load() != self, let data = try? JSONEncoder().encode(self) else { return false }
        try? data.write(to: file, options: .atomic)
        return true
    }

    /// Due on a given day: overdue or for that day, not yet ticked in a widget.
    func due(on date: Date, calendar: Calendar = .current) -> [Item] {
        let today = calendar.startOfDay(for: date)
        let ticked = Set(Self.ticked)
        return items.filter { $0.day <= today && !ticked.contains($0.id) }
    }

    // MARK: Ticked in a widget

    private static var shared: UserDefaults? { UserDefaults(suiteName: group) }

    /// Ticked off in a widget, waiting for the app to mark them done.
    static var ticked: [String] { shared?.stringArray(forKey: "widget.ticked") ?? [] }

    static func tick(_ id: String) {
        guard !ticked.contains(id) else { return }
        shared?.set(ticked + [id], forKey: "widget.ticked")
    }

    /// The app takes them, once it has marked them done.
    static func takeTicked() -> [String] {
        let all = ticked
        shared?.removeObject(forKey: "widget.ticked")
        return all
    }
}

/// Ticks a to-do off from a widget. Shown done at once; roko marks it done in
/// its list the next time it opens.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick Off To-do"
    static let isDiscoverable = false

    @Parameter(title: "To-do") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        WidgetSnapshot.tick(id)
        return .result()
    }
}
