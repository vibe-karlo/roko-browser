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
/// "call Petra on Monday at 15". When comes at the end, in either order with
/// a time: today, tomorrow, the day after, a weekday ("monday", "on friday",
/// "next tuesday"), this week, next week, someday, "in 3 days", a date
/// ("24.11."), in English or Croatian ("sutra", "u petak", "sljedeći tjedan",
/// "za 3 dana"). Without one, today.
nonisolated enum TodoDraft {
    static func parse(_ query: String, now: Date = .now) -> (title: String, when: TodoWhen, time: DateComponents?)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard let prefix = ["todo ", "to-do ", "to do ", "+"].first(where: { lower.hasPrefix($0) }),
              let read = read(String(trimmed.dropFirst(prefix.count)), now: now), !read.title.isEmpty else { return nil }
        return (read.title, read.when ?? .today, read.time)
    }

    /// A to-do's words, with any day and time at their end taken off and
    /// read: "Call Petra on Monday at 13:00" is "Call Petra", Monday, 13:00.
    /// `when` and `time` are nil where nothing said them. As typed in To-do,
    /// with no "todo" in front.
    static func read(_ text: String, now: Date = .now) -> (title: String, when: TodoWhen?, time: DateComponents?)? {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var when: TodoWhen?
        var time: DateComponents?
        // Said first, as people do ("sutra nazvati mamu", "tomorrow call Ana"):
        // a day at the start is read as if it came at the end.
        let words = title.split(separator: " ")
        for count in stride(from: min(3, words.count - 1), through: 1, by: -1) {
            let head = words.prefix(count).joined(separator: " ")
            if let (day, rest) = trailingDay("x " + head, now: now), rest == "x" {
                when = day
                title = words.dropFirst(count).joined(separator: " ")
                break
            }
        }
        // "tomorrow at 15" or "at 15 tomorrow": either order.
        for _ in 0..<2 {
            if time == nil, let (clock, rest) = trailingTime(title) {
                time = clock
                title = rest
            } else if when == nil, let (day, rest) = trailingDay(title, now: now) {
                when = day
                title = rest
            }
        }
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
        // "at 3", no am, no minutes past: the afternoon, as it's meant. 1 to 6 only:
        // "at 7" or "at 8" may well be the morning.
        if suffix == nil, group(2) == nil, group(5) == nil, (1...6).contains(hour) { hour += 12 }
        guard (0..<24).contains(hour), (0..<60).contains(minute),
              let whole = Range(match.range, in: text) else { return nil }
        let rest = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (DateComponents(hour: hour, minute: minute), rest)
    }

    /// Weekdays by Calendar's numbering (1 is Sunday), in English and Croatian
    /// (with the forms after "u": "u srijedu", "u subotu", "u nedjelju").
    private static let weekdays: [(String, Int)] = [
        ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7), ("sunday", 1),
        ("ponedjeljak", 2), ("utorak", 3), ("srijeda", 4), ("srijedu", 4), ("četvrtak", 5), ("cetvrtak", 5),
        ("petak", 6), ("subota", 7), ("subotu", 7), ("nedjelja", 1), ("nedjelju", 1),
    ]

    /// The day at the end of `text`, and what's before it.
    private static func trailingDay(_ text: String, now: Date) -> (TodoWhen, String)? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let lower = text.lowercased()
        func rest(dropping phrase: String) -> String? {
            String(text.dropLast(phrase.count)).trimmingCharacters(in: .whitespaces)
        }
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

        // Words and phrases, longest first so "day after tomorrow" wins over "tomorrow".
        var phrases: [(String, TodoWhen)] = [
            ("the day after tomorrow", .date(day(2))), ("day after tomorrow", .date(day(2))), ("prekosutra", .date(day(2))),
            ("tomorrow", .tomorrow), ("sutra", .tomorrow), ("today", .today), ("danas", .today),
            ("this week", .thisWeek), ("ovaj tjedan", .thisWeek), ("ovog tjedna", .thisWeek),
            ("someday", .someday),
        ]
        // Next week: its first day. "Next friday": the Friday of next week.
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
        let nextWeekStart = calendar.startOfDay(for: thisWeek.end)
        for phrase in ["next week", "sljedeći tjedan", "sljedeci tjedan", "idući tjedan", "iduci tjedan", "sljedećeg tjedna"] {
            phrases.append((phrase, .date(nextWeekStart)))
        }
        // A weekday on its own: the next one from today (today itself if it's that day).
        let todayNumber = calendar.component(.weekday, from: today)
        for (name, number) in weekdays {
            let ahead = (number - todayNumber + 7) % 7
            let coming: TodoWhen = ahead == 0 ? .today : ahead == 1 ? .tomorrow : .date(day(ahead))
            let intoNextWeek = (number - calendar.firstWeekday + 7) % 7
            let nextWeeks = TodoWhen.date(calendar.date(byAdding: .day, value: intoNextWeek, to: nextWeekStart)!)
            for prefix in ["", "on ", "this ", "u ", "ovaj ", "ovu ", "na "] { phrases.append((prefix + name, coming)) }
            for prefix in ["next ", "sljedeći ", "sljedeću ", "sljedeci ", "sljedecu ", "idući ", "iduću ", "iduci ", "iducu "] {
                phrases.append((prefix + name, nextWeeks))
            }
        }
        for (phrase, when) in phrases.sorted(by: { $0.0.count > $1.0.count }) {
            if lower.hasSuffix(" " + phrase), let kept = rest(dropping: " " + phrase) { return (when, kept) }
            if lower == phrase { return (when, "") }
        }

        // "in 3 days", "za 3 dana".
        let inDays = #"\s+(?:in|za)\s+(\d{1,3})\s+(?:days?|dana?)$"#
        if let match = lower.range(of: inDays, options: .regularExpression),
           let count = Int(lower[match].filter(\.isNumber)), let kept = rest(dropping: String(text[match])) {
            return (count == 0 ? .today : count == 1 ? .tomorrow : .date(day(count)), kept)
        }

        // A date: "24.11.", "24.11.2026", "24/11", optionally after "on" or "na".
        let datePattern = #"\s+(?:on\s+|na\s+)?(\d{1,2})[./](\d{1,2})\.?(?:[./]?(\d{4})\.?)?$"#
        guard let regex = try? NSRegularExpression(pattern: datePattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let dayRange = Range(match.range(at: 1), in: lower), let monthRange = Range(match.range(at: 2), in: lower),
              let whole = Range(match.range, in: lower) else { return nil }
        var parts = DateComponents(month: Int(lower[monthRange]), day: Int(lower[dayRange]))
        if let yearRange = Range(match.range(at: 3), in: lower) {
            parts.year = Int(lower[yearRange])
        } else {
            parts.year = calendar.component(.year, from: today)
        }
        guard (1...12).contains(parts.month ?? 0), (1...31).contains(parts.day ?? 0),
              var date = calendar.date(from: parts) else { return nil }
        // Without a year, a day already gone this year means next year's.
        if match.range(at: 3).location == NSNotFound, date < today {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        guard let kept = rest(dropping: String(lower[whole])) else { return nil }
        let ahead = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        return (ahead == 0 ? .today : ahead == 1 ? .tomorrow : .date(date), kept)
    }

    /// "Today", "Tomorrow at 15:00", "Mon 26 Oct".
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
        case .date(let date): date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// Short, for a chip beside a field: "Today", "Tmrw 9:00", "Wed 15:00", "3 Nov".
    static func short(_ when: TodoWhen, _ time: DateComponents?, now: Date = .now) -> String {
        var day: String
        switch when {
        case .today: day = time == nil ? "Today" : ""
        case .tomorrow: day = "Tomorrow"
        case .thisWeek: day = "This week"
        case .someday: day = "Someday"
        case .date(let date):
            let ahead = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: date).day ?? 0
            day = ahead < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated))
        }
        guard let time, let clock = Calendar.current.date(from: time) else { return day }
        return (day.isEmpty ? "" : day + " ") + clock.formatted(date: .omitted, time: .shortened)
    }

    /// For a sentence: "today", "tomorrow at 15:00", "Monday", "Mon 9 Nov at 15:00".
    static func phrase(_ when: TodoWhen, _ time: DateComponents?, now: Date = .now) -> String {
        var words: String
        switch when {
        case .today: words = "today"
        case .tomorrow: words = "tomorrow"
        case .thisWeek: words = "this week"
        case .someday: words = "someday"
        case .date(let date):
            let ahead = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: date).day ?? 0
            words = ahead < 7 ? date.formatted(.dateTime.weekday(.wide)) : label(when)
        }
        if let time, let clock = Calendar.current.date(from: time) {
            words += " at " + clock.formatted(date: .omitted, time: .shortened)
        }
        return words
    }
}
