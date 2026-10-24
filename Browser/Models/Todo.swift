import Foundation
import SwiftData

/// One to-do in roko's single list. When it's for is a day (or a week, or
/// someday); the list sorts itself into Overdue, Today, Tomorrow, This week,
/// Later and Someday from that, so nothing ever needs moving by hand when a
/// day passes. Like every model here: defaults everywhere, ready for iCloud.
@Model
final class Todo {
    var title: String = ""
    /// The day it's for, at its start; nil is Someday.
    var day: Date? = nil
    /// "This week": `day` is the week's last day, and until then it waits
    /// under This week rather than on a particular day.
    var wholeWeek: Bool = false
    var done: Bool = false
    var doneAt: Date? = nil
    var createdAt: Date = Date.now

    init(title: String, when: TodoWhen, now: Date = .now) {
        self.title = title
        schedule(when, now: now)
    }

    /// Moves it to a day, a week or someday.
    func schedule(_ when: TodoWhen, now: Date = .now) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        switch when {
        case .today:
            day = today
            wholeWeek = false
        case .tomorrow:
            day = calendar.date(byAdding: .day, value: 1, to: today)
            wholeWeek = false
        case .thisWeek:
            day = TodoSection.lastDayOfWeek(containing: today)
            wholeWeek = true
        case .date(let date):
            day = calendar.startOfDay(for: date)
            wholeWeek = false
        case .someday:
            day = nil
            wholeWeek = false
        }
    }
}

nonisolated enum TodoWhen: Hashable {
    case today, tomorrow, thisWeek, date(Date), someday
}

/// Where a to-do shows, worked out from its day and today's date.
nonisolated enum TodoSection: Int, CaseIterable, Identifiable {
    case overdue, today, tomorrow, thisWeek, later, someday

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This week"
        case .later: "Later"
        case .someday: "Someday"
        }
    }

    static func of(_ todo: Todo, now: Date = .now) -> TodoSection {
        guard let day = todo.day else { return .someday }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if day < today { return .overdue }
        if day == today { return .today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        if day == tomorrow, !todo.wholeWeek { return .tomorrow }
        return day <= lastDayOfWeek(containing: today) ? .thisWeek : .later
    }

    /// The week's last day in the phone's calendar (Sunday where weeks start on Monday).
    static func lastDayOfWeek(containing day: Date) -> Date {
        let calendar = Calendar.current
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return day }
        return calendar.date(byAdding: .day, value: -1, to: week.end).map(calendar.startOfDay) ?? day
    }
}

extension Todo {
    /// Due today or before and not done: what the count beside the pins shows.
    var isDueNow: Bool {
        guard !done else { return false }
        let section = TodoSection.of(self)
        return section == .overdue || section == .today
    }

    /// Done today, of those that were due by today: the filled part of the ring.
    var wasDoneToday: Bool {
        guard done, let doneAt, Calendar.current.isDateInToday(doneAt), let day else { return false }
        return day <= Calendar.current.startOfDay(for: .now)
    }
}
