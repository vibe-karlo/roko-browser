import Foundation

/// Dates, Raycast-style: "now", "today", "tomorrow", "days until 31 mar",
/// "days since 1 jan", "in 90 days", "monday in 3 weeks", "next friday",
/// "christmas + 10 days", "week number", "unix time", "1700000000 to date".
enum DateMath {
    static func answer(_ text: String) -> CalculatorAnswer? {
        switch text {
        case "now":
            return CalculatorAnswer(result: Date.now.formatted(date: .omitted, time: .shortened), question: long(.now))
        case "today", "date":
            return CalculatorAnswer(result: long(.now), question: "Today · week \(week(.now))")
        case "tomorrow", "yesterday":
            let date = calendar.date(byAdding: .day, value: text == "tomorrow" ? 1 : -1, to: .now)!
            return CalculatorAnswer(result: long(date), question: text.capitalized)
        case "week", "week number", "what week is it", "current week", "what week":
            return CalculatorAnswer(result: "Week \(week(.now))", question: long(.now))
        case "unix", "unix time", "timestamp", "unix timestamp", "epoch":
            let seconds = Int(Date.now.timeIntervalSince1970)
            return CalculatorAnswer(result: "\(seconds)", question: "Unix time now")
        default:
            return countdown(text) ?? fromUnix(text) ?? shifted(text)
        }
    }

    // MARK: Questions

    /// "days until 31 mar", "how many days until christmas", "weeks until summer", "days since 1 jan".
    private static func countdown(_ text: String) -> CalculatorAnswer? {
        guard text.hasPrefix("days ") || text.hasPrefix("weeks ") || text.hasPrefix("how many "),
              let match = text.wholeMatch(of: countdownPattern), let target = date(String(match.3), future: match.2 != "since")
        else { return nil }
        let start = calendar.startOfDay(for: .now), end = calendar.startOfDay(for: target)
        let days = abs(calendar.dateComponents([.day], from: start, to: end).day ?? 0)
        let value = match.1 == "weeks" ? "\(Calculator.format(Double(days) / 7, maxFractionDigits: 1)) weeks" : "\(days) \(days == 1 ? "day" : "days")"
        return CalculatorAnswer(result: value, question: "\(match.2 == "since" ? "Since" : "Until") \(long(target))")
    }

    private static let countdownPattern = /(?:how many )?(days|weeks) (until|till|til|to|since|from) (.+)/

    /// "1700000000 to date", "1700000000 unix".
    private static func fromUnix(_ text: String) -> CalculatorAnswer? {
        guard text.first?.isNumber == true, text.hasSuffix("date") || text.hasSuffix("unix"),
              let match = text.wholeMatch(of: unixPattern), let seconds = Double(match.1) else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return CalculatorAnswer(result: "\(long(date)), \(date.formatted(date: .omitted, time: .shortened))",
                                question: "Unix time \(match.1)")
    }

    private static let unixPattern = /(\d{9,11}) (?:to date|as date|in date|unix)/

    /// "in 3 weeks", "90 days from now", "monday in 3 weeks", "today + 10 days",
    /// "christmas - 2 weeks", "next friday", "date in 90 days".
    private static func shifted(_ text: String) -> CalculatorAnswer? {
        // Cheap check first: a span of days to move by, a sum, or "next <day>".
        let hasSpan = ["day", "week", "month", "year"].contains(where: text.contains)
        guard hasSpan || text.contains("+") || text.contains("-") || text.hasPrefix("next ") else { return nil }
        var text = text
        if text.hasPrefix("date ") { text.removeFirst(5) }

        var base = "today", sign = 1, amount = 0, unit = "day"
        if hasSpan, let match = text.wholeMatch(of: inPattern) {
            base = match.1.map(String.init) ?? "today"
            (amount, unit) = (Int(match.2) ?? 0, String(match.3))
        } else if hasSpan, let match = text.wholeMatch(of: fromNowPattern) {
            (amount, unit) = (Int(match.1) ?? 0, String(match.2))
        } else if hasSpan, let match = text.wholeMatch(of: agoPattern) {
            (amount, unit, sign) = (Int(match.1) ?? 0, String(match.2), -1)
        } else if let match = text.wholeMatch(of: sumPattern) {
            base = String(match.1)
            sign = match.2 == "-" ? -1 : 1
            (amount, unit) = (Int(match.3) ?? 0, match.4.map(String.init) ?? "day")
        } else if text.hasPrefix("next "), weekdayIndex(String(text.dropFirst(5))) != nil {
            base = String(text.dropFirst(5))
        } else {
            return nil
        }
        // Only things that name a date; "5 + 3 days" is not one. Nor a million years away.
        guard amount <= 100_000, let start = date(base, future: true) else { return nil }
        let component: Calendar.Component = unit.hasPrefix("w") ? .weekOfYear : unit.hasPrefix("m") ? .month
            : unit.hasPrefix("y") ? .year : .day
        guard let result = calendar.date(byAdding: component, value: sign * amount, to: start) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: result)).day ?? 0
        let distance = days == 0 ? "today" : days > 0 ? "in \(days) \(days == 1 ? "day" : "days")" : "\(-days) days ago"
        return CalculatorAnswer(result: long(result), question: distance == text ? text : "\(text) · \(distance)")
    }

    private static let inPattern = /(?:(.+?) )?in (\d+) (days?|weeks?|months?|years?)/
    private static let fromNowPattern = /(\d+) (days?|weeks?|months?|years?) (?:from now|from today|later)/
    private static let agoPattern = /(\d+) (days?|weeks?|months?|years?) ago/
    private static let sumPattern = /(.+?) ?([+-]) ?(\d+) ?(days?|d|weeks?|w|months?|years?)?/

    // MARK: Reading dates

    /// "today", "christmas", "friday", "31 mar", "mar 31 2027", "31.3.", "2027-03-31".
    /// Without a year, the next one when `future`, the last one otherwise.
    static func date(_ raw: String, future: Bool) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let today = calendar.startOfDay(for: .now)
        switch text {
        case "today", "now": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        if let (month, day) = holidays[text] {
            return nearest(month: month, day: day, future: future)
        }
        if let weekday = weekdayIndex(text) {
            let components = DateComponents(weekday: weekday)
            return calendar.nextDate(after: today, matching: components, matchingPolicy: .nextTime,
                                     direction: future ? .forward : .backward)
        }
        for formatter in fullDateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        for formatter in dayMonthFormatters {
            guard let parsed = formatter.date(from: text) else { continue }
            let parts = calendar.dateComponents([.month, .day], from: parsed)
            return nearest(month: parts.month ?? 1, day: parts.day ?? 1, future: future)
        }
        return nil
    }

    private static func nearest(month: Int, day: Int, future: Bool) -> Date? {
        let today = calendar.startOfDay(for: .now)
        let year = calendar.component(.year, from: today)
        guard let thisYear = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        if future, thisYear < today { return calendar.date(byAdding: .year, value: 1, to: thisYear) }
        if !future, thisYear > today { return calendar.date(byAdding: .year, value: -1, to: thisYear) }
        return thisYear
    }

    private static func weekdayIndex(_ text: String) -> Int? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        guard text.count >= 3 else { return nil }
        return names.firstIndex { $0 == text || $0.hasPrefix(text) && text.count >= 3 }.map { $0 + 1 }
    }

    private static let holidays: [String: (Int, Int)] = [
        "christmas": (12, 25), "xmas": (12, 25), "christmas eve": (12, 24), "new year": (1, 1),
        "new years": (1, 1), "new year's day": (1, 1), "new year's eve": (12, 31), "new years eve": (12, 31),
        "halloween": (10, 31), "valentine's day": (2, 14), "valentines day": (2, 14), "valentines": (2, 14),
    ]

    // Built once, on first use: formatters are costly to create.
    private static func formatters(_ formats: [String]) -> [DateFormatter] {
        formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter
        }
    }

    private static let fullDateFormatters = formatters([
        "yyyy-MM-dd", "d MMM yyyy", "d MMMM yyyy", "MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy",
        "d.M.yyyy", "d.M.yyyy.", "d. M. yyyy.", "d/M/yyyy",
    ])

    private static let dayMonthFormatters = formatters([
        "d MMM", "d MMMM", "MMM d", "MMMM d", "d.M.", "d.M", "d. M.", "d/M",
    ])

    // MARK: Writing dates

    private static var calendar: Calendar { .current }

    private static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private static func week(_ date: Date) -> Int {
        Calendar(identifier: .iso8601).component(.weekOfYear, from: date)
    }
}
