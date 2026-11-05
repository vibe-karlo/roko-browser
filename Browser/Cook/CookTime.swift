import Foundation

/// Times written in a recipe's step: "30 mins", "8-10 minutes", "1 hour 15 mins",
/// "half an hour", and in Croatian "30 minuta", "pola sata". A range counts as its lower end: better to look too early
/// than to find it burnt.
nonisolated enum CookTime {
    struct Found: Equatable {
        let range: Range<String.Index>
        let seconds: Int
    }

    private static let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                "nine": 9, "ten": 10, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
                                "forty": 40, "forty-five": 45, "sixty": 60, "a": 1, "an": 1]
    private static let number = #"[0-9]+(?:[.,][0-9]+)?(?:\s*(?:[¼½¾]|[0-9]/[0-9]))?|[¼½¾]|[0-9]/[0-9]|forty-five|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|forty|sixty|an?"#
    private static let hours = #"hours?|hrs?|h|sati|sata|sat"#
    private static let minutes = #"minutes?|minuta|minutu|mins?"#
    private static let seconds = #"seconds?|secs?|sekund[aei]?"#
    private static let pattern = try? NSRegularExpression(pattern: #"""
        (?<![\w.,/])(?:
          (half\s+an?\s+hour|quarter\s+of\s+an\s+hour|pola\s+sata)
          |
          (\#(number))(?:\s*(?:-|\u2013|\u2014|to|or|do|ili)\s*(?:\#(number)))?[\s-]*(\#(hours)|\#(minutes)|\#(seconds))\b
          (?:\s*(?:and|i|,)?\s*(\#(number))[\s-]*(\#(minutes))\b)?
        )
        """#, options: [.caseInsensitive, .allowCommentsAndWhitespace])

    static func find(in text: String) -> [Found] {
        guard let pattern else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { String(text[$0]).lowercased() }
            }
            let total: Double
            if let phrase = group(1) {
                total = phrase.hasPrefix("quarter") ? 900 : 1800
            } else {
                guard let amount = group(2).flatMap(value), let unit = group(3) else { return nil }
                let isHours = unit.hasPrefix("h") || unit.hasPrefix("sat")
                let size: Double = isHours ? 3600 : unit.hasPrefix("m") ? 60 : 1
                let extra = group(4).flatMap(value).map { group(5) != nil && isHours ? $0 * 60 : 0 } ?? 0
                total = amount * size + extra
            }
            // Past a day it's storing, not cooking. Under a few seconds it's the
            // word and not a time: "use a second bowl".
            guard total >= 5, total < 86_400 else { return nil }
            return Found(range: range, seconds: Int(total.rounded()))
        }
    }

    /// "3", "1.5", "1 1/2", "1½", "½", "two".
    private static func value(_ written: String) -> Double? {
        if let word = words[written] { return Double(word) }
        var whole = 0.0, rest = written
        if let digits = rest.range(of: #"^[0-9]+(?:[.,][0-9]+)?(?!/)"#, options: .regularExpression) {
            whole = Double(rest[digits].replacingOccurrences(of: ",", with: ".")) ?? 0
            rest = String(rest[digits.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        switch rest {
        case "": return whole
        case "¼": return whole + 0.25
        case "½": return whole + 0.5
        case "¾": return whole + 0.75
        default:
            let parts = rest.split(separator: "/").compactMap { Double($0) }
            return parts.count == 2 && parts[1] != 0 ? whole + parts[0] / parts[1] : nil
        }
    }
}
