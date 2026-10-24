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
    /// When on its day, if it has a time: a notification comes 15 minutes before.
    var time: Date? = nil
    /// Its place in its section, dragged there; 0 until it's been moved, then
    /// the order it was added in decides.
    var order: Double = 0

    init(title: String, when: TodoWhen, at time: DateComponents? = nil, now: Date = .now) {
        self.title = title
        schedule(when, now: now)
        if let time { setTime(time) }
    }

    /// Moves it to a day, a week or someday. A time moves with it to another
    /// day; a week or someday has none.
    func schedule(_ when: TodoWhen, now: Date = .now) {
        let calendar = Calendar.current
        let clock = time.map { calendar.dateComponents([.hour, .minute], from: $0) }
        defer {
            if let clock, !wholeWeek, day != nil { setTime(clock) } else { time = nil }
        }
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

    /// A time on its day (today's, if it has none), or no time.
    func setTime(_ clock: DateComponents?) {
        guard let clock else { time = nil; return }
        let calendar = Calendar.current
        if day == nil || wholeWeek {
            day = calendar.startOfDay(for: .now)
            wholeWeek = false
        }
        time = calendar.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day!)
    }

    /// "15:30", when it has a time.
    var timeLabel: String? {
        time?.formatted(date: .omitted, time: .shortened)
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

/// A to-do typed into the address bar: "todo call Petra", "+ call Petra",
/// "todo call Petra tomorrow". A trailing day word (today, tomorrow, this
/// week, someday, or Croatian danas, sutra) says when; without one, today.
nonisolated enum TodoDraft {
    static func parse(_ query: String) -> (title: String, when: TodoWhen, time: DateComponents?)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard let prefix = ["todo ", "to-do ", "to do ", "+"].first(where: { lower.hasPrefix($0) }) else { return nil }
        var title = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        var when = TodoWhen.today
        var time: DateComponents?
        let endings: [(String, TodoWhen)] = [("this week", .thisWeek), ("ovaj tjedan", .thisWeek), ("tomorrow", .tomorrow),
                                             ("sutra", .tomorrow), ("today", .today), ("danas", .today), ("someday", .someday)]
        // "tomorrow at 15" or "at 15 tomorrow": either order.
        for _ in 0..<2 {
            if time == nil, let (clock, rest) = trailingTime(title) {
                time = clock
                title = rest
                continue
            }
            if let (word, day) = endings.first(where: { title.lowercased().hasSuffix(" " + $0.0) }) {
                title = String(title.dropLast(word.count + 1)).trimmingCharacters(in: .whitespaces)
                when = day
            }
        }
        guard !title.isEmpty else { return nil }
        return (title.prefix(1).uppercased() + title.dropFirst(), when, time)
    }

    /// "… at 15", "… at 3pm", "… u 15h", "… 15:30": the time, and what's before it.
    /// A bare number ("buy 2") isn't a time.
    private static func trailingTime(_ text: String) -> (DateComponents, String)? {
        let pattern = #"\s+(?:(?:at|u|@)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(h|am|pm)?|(\d{1,2})[:.](\d{2})\s*(am|pm)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard var hour = Int(group(1) ?? group(4) ?? "") else { return nil }
        let minute = Int(group(2) ?? group(5) ?? "0") ?? 0
        let suffix = (group(3) ?? group(6))?.lowercased()
        if suffix == "pm", hour < 12 { hour += 12 }
        if suffix == "am", hour == 12 { hour = 0 }
        guard (0..<24).contains(hour), (0..<60).contains(minute),
              let whole = Range(match.range, in: text) else { return nil }
        let rest = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (DateComponents(hour: hour, minute: minute), rest)
    }

    /// "Today", "Tomorrow at 15:00".
    static func label(_ when: TodoWhen, _ time: DateComponents?) -> String {
        guard let time, let date = Calendar.current.date(from: time) else { return label(when) }
        return label(when) + " at " + date.formatted(date: .omitted, time: .shortened)
    }

    static func label(_ when: TodoWhen) -> String {
        switch when {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This week"
        case .someday: "Someday"
        case .date(let date): date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
