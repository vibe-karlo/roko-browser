import SwiftData
import WidgetKit

/// Keeps the Home Screen widgets' copy (WidgetSnapshot) current: written
/// after every save that touched a to-do and every new weather, and only
/// when it changed, so widgets reload just as often as there's news.
@MainActor
enum WidgetBridge {
    private static var container: ModelContainer?
    /// The bar's pinned answers, as it last showed them.
    private static var answers: [WidgetSnapshot.Answer] = WidgetSnapshot.load()?.answers ?? []

    /// From the bar, each time it lists your pinned answers; written only when
    /// what they say changed.
    static func setAnswers(_ rows: [(asked: String, title: String, subtitle: String, icon: String?)]) {
        let fresh = rows.map { WidgetSnapshot.Answer(id: $0.asked, title: $0.title, subtitle: $0.subtitle, icon: $0.icon, updated: .now) }
        let same = fresh.count == answers.count && zip(fresh, answers).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.subtitle == $1.subtitle && $0.icon == $1.icon
        }
        guard !same else { return }
        answers = fresh
        update()
    }

    static func start(_ container: ModelContainer) {
        self.container = container
        applyTicks()
        update()
    }

    /// The id a widget knows a to-do by: when it was made.
    static func id(_ todo: Todo) -> String {
        String(todo.createdAt.timeIntervalSinceReferenceDate)
    }

    /// To-dos ticked off in a widget, marked done in the list.
    static func applyTicks() {
        let ticked = Set(WidgetSnapshot.takeTicked())
        if LaunchClock.isEnabled { print("WIDGET ticks \(ticked.count)") }
        guard !ticked.isEmpty, let context = container?.mainContext else { return }
        for todo in (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { !$0.done }))) ?? []
        where ticked.contains(id(todo)) {
            todo.done = true
            todo.doneAt = .now
        }
        try? context.save()
    }

    static func update() {
        guard let context = container?.mainContext else { return }
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) else { return }
        let all = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        // Due by tomorrow: at midnight tomorrow's become today's without the app opening.
        let items = all
            .filter { !$0.done && ($0.day.map { $0 <= tomorrow } ?? false) }
            .sorted { a, b in a.day == b.day ? Todo.listOrder(a, b) : (a.day ?? .distantFuture) < (b.day ?? .distantFuture) }
            .prefix(16)
            .map { WidgetSnapshot.Item(id: id($0), title: $0.title, day: $0.day ?? tomorrow, time: $0.time) }
        let weather = TodayModel.shared.weather.map {
            WidgetSnapshot.Weather(temperature: $0.temperature, condition: $0.condition, glyph: $0.glyph,
                                   high: $0.high, low: $0.low, rainChance: $0.rainChance, place: $0.place,
                                   fetchedAt: $0.fetchedAt)
        }
        let snapshot = WidgetSnapshot(items: Array(items), doneToday: all.filter(\.wasDoneToday).count,
                                      weather: weather, answers: answers)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
