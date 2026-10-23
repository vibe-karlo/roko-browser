import Foundation

/// A Raycast-style answer to whatever is typed in the command bar: arithmetic,
/// percentages, unit and currency conversions, dates, and the time in other
/// places. Pure, synchronous and cheap; a quick pre-check rejects ordinary text
/// before any parsing happens, so typing a search never pays for it.
struct CalculatorAnswer: Equatable {
    /// What to show and copy, e.g. "3.11 mi".
    let result: String
    /// The question restated, e.g. "5 km in miles".
    let question: String
}

enum Calculator {
    static func answer(_ input: String) -> CalculatorAnswer? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.count <= 120 else { return nil }
        let lower = clean(text.lowercased())
        guard mightBeAnswerable(lower) else { return nil }
        return DateMath.answer(lower)
            ?? TimeZoneLookup.answer(lower)
            ?? Conversion.answer(lower)
            ?? percentage(lower)
            ?? arithmetic(lower)
    }

    /// Drops the wrapping people type around a question: "what is", "?", "=".
    private static func clean(_ text: String) -> String {
        var text = text
        for prefix in ["what is ", "what's ", "whats ", "calculate ", "calc ", "convert "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        while let last = text.last, last == "?" || last == "=" || last == " " { text.removeLast() }
        return text
    }

    /// Microsecond-cheap gate. With digits: also an operator or a word ("2025"
    /// or a phone number alone isn't a question). Without: one of the word
    /// questions the date and time answers understand.
    private static func mightBeAnswerable(_ lower: String) -> Bool {
        if lower.contains(where: \.isNumber) {
            return lower.contains(where: { "+-*/×÷^%()!".contains($0) || Conversion.symbols[$0] != nil || $0.isLetter })
        }
        if lower.hasSuffix(" time") || wordQuestions.contains(lower) { return true }
        return wordStarts.contains { lower.hasPrefix($0) }
    }

    private static let wordQuestions: Set<String> = [
        "now", "today", "tomorrow", "yesterday", "time", "date", "week", "week number", "unix", "timestamp",
    ]
    private static let wordStarts = [
        "time ", "days ", "weeks ", "how many days", "diff ", "what time", "current time", "next ",
        "what week", "current week", "pi", "square root", "sqrt",
    ]

    /// "15 is what % of 60", "what % of 60 is 15".
    private static func percentage(_ text: String) -> CalculatorAnswer? {
        guard text.contains("what") else { return nil }
        for (index, pattern) in percentagePatterns.enumerated() {
            guard let match = text.wholeMatch(of: pattern),
                  let first = match.output[1].substring, let second = match.output[2].substring,
                  let a = Expression.evaluate(String(first)), let b = Expression.evaluate(String(second)) else { continue }
            let (part, whole) = index == 0 ? (a, b) : (b, a)
            guard whole != 0 else { return nil }
            return CalculatorAnswer(result: "\(format(part / whole * 100, maxFractionDigits: 4))%",
                                    question: "\(format(part)) of \(format(whole))")
        }
        return nil
    }

    private static let percentagePatterns = [
        try! Regex(#"(.+?) is what ?(?:%|percent) of (.+)"#),
        try! Regex(#"what ?(?:%|percent) of (.+?) is (.+)"#),
    ]

    private static func arithmetic(_ text: String) -> CalculatorAnswer? {
        let spoken = naturalized(text)
        guard let value = Expression.evaluate(spoken), value.isFinite else { return nil }
        // "12" or "3.5" alone parse fine but aren't worth answering.
        if Double(text.replacingOccurrences(of: ",", with: "")) != nil { return nil }
        return CalculatorAnswer(result: format(value), question: text)
    }

    /// Spoken maths to symbols: "square root of 625", "2 power 10", "5 squared".
    private static func naturalized(_ text: String) -> String {
        guard text.contains(where: { $0.isLetter }) else { return text }
        var text = " \(text) "
        for (spoken, symbol) in spokenOperators {
            text = text.replacingOccurrences(of: spoken, with: symbol)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let spokenOperators: [(String, String)] = [
        ("square root of ", "sqrt "), ("sqrt of ", "sqrt "), ("cube root of ", "cbrt "),
        (" to the power of ", "^"), (" to the power ", "^"), (" raised to ", "^"), (" power ", "^"), (" pow ", "^"),
        (" squared ", "^2 "), (" cubed ", "^3 "),
        (" plus ", " + "), (" minus ", " - "), (" times ", " * "), (" multiplied by ", " * "),
        (" divided by ", " / "), (" over ", " / "), (" percent ", "% "), (" pct ", "% "),
    ]

    // Formatters are costly to create, so they're made once.
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let scientific: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .scientific
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    static func format(_ value: Double, maxFractionDigits: Int = 6) -> String {
        let tiny = abs(value) < 1e-6 && value != 0
        if abs(value) >= 1e15 || tiny {
            return scientific.string(from: NSNumber(value: value)) ?? String(value)
        }
        decimal.maximumFractionDigits = maxFractionDigits
        return decimal.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Arithmetic

/// Recursive-descent evaluator. Understands + - * / ^, × ÷, "x" between numbers,
/// parentheses, unary minus, factorial (5!), mod, the usual functions, pi and e,
/// "10k" and "2 million", "20% of 50", "20% off 80", "20% on 80", and
/// "100 + 10%" (adds ten percent, as people mean it).
enum Expression {
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(tokens: tokenize(text))
        guard let value = parser.expression(), parser.atEnd else { return nil }
        return value.number
    }

    fileprivate enum Token: Equatable {
        case number(Double), word(String), op(Character), open, close, percent
    }

    private static let multipliers: [String: Double] = [
        "k": 1e3, "thousand": 1e3, "million": 1e6, "mil": 1e6, "mio": 1e6, "mn": 1e6,
        "billion": 1e9, "bn": 1e9, "trillion": 1e12,
    ]

    fileprivate static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        // Drop thousands separators ("1,000,000"); any other comma between
        // digits is a decimal comma, as Croatia and most of Europe write it ("12,50").
        let chars = Array(text.contains(",")
            ? text.replacingOccurrences(of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=\d),(?=\d)"#, with: ".", options: .regularExpression)
            : text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let number = Double(String(chars[i..<j])) else { return [] }
                tokens.append(.number(number))
                i = j
            } else if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j])
                if word == "x", case .number = tokens.last, j < chars.count, chars[j].isNumber || chars[j] == " " {
                    // "3x4": an x between numbers means times.
                    tokens.append(.op("*"))
                } else if let factor = multipliers[word], case .number(let n)? = tokens.last,
                          word != "k" || chars[i - 1].isNumber {
                    // "10k", "2.5 million". A spaced "k" is something else.
                    tokens[tokens.count - 1] = .number(n * factor)
                } else {
                    tokens.append(.word(word))
                }
                i = j
            } else {
                switch c {
                case "+", "-", "*", "/", "^", "!": tokens.append(.op(c))
                case "×", "·": tokens.append(.op("*"))
                case "÷": tokens.append(.op("/"))
                case "−": tokens.append(.op("-"))
                case "(": tokens.append(.open)
                case ")": tokens.append(.close)
                case "%": tokens.append(.percent)
                case "π": tokens.append(.word("pi"))
                case "°": tokens.append(.word("deg"))
                case "√": tokens.append(.word("sqrt"))
                default: return []
                }
                i += 1
            }
        }
        return tokens
    }

    /// A value that remembers if it was written as a percentage, for "100 + 10%".
    fileprivate struct Value {
        var number: Double
        var isPercent = false
    }

    fileprivate struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool { index == tokens.count && !tokens.isEmpty }
        private var current: Token? { index < tokens.count ? tokens[index] : nil }
        private mutating func advance() { index += 1 }

        mutating func expression() -> Value? {
            guard var left = term() else { return nil }
            while case .op(let op)? = current, op == "+" || op == "-" {
                advance()
                guard let right = term() else { return nil }
                let amount = right.isPercent ? left.number * right.number : right.number
                left = Value(number: op == "+" ? left.number + amount : left.number - amount)
            }
            return left
        }

        private mutating func term() -> Value? {
            guard var left = power() else { return nil }
            while true {
                if case .op(let op)? = current, op == "*" || op == "/" {
                    advance()
                    guard let right = power() else { return nil }
                    left = Value(number: op == "*" ? left.number * right.number : left.number / right.number)
                } else if case .word(let word)? = current, left.isPercent, ["of", "off", "on"].contains(word) {
                    // "20% of 80" = 16, "20% off 80" = 64, "20% on 80" = 96.
                    advance()
                    guard let right = power() else { return nil }
                    let share = left.number * right.number
                    left = Value(number: word == "of" ? share : word == "off" ? right.number - share : right.number + share)
                } else if case .word("mod")? = current {
                    advance()
                    guard let right = power() else { return nil }
                    left = Value(number: fmod(left.number, right.number))
                } else if case .open? = current {
                    // Implicit multiplication: "2(3+4)".
                    guard let right = power() else { return nil }
                    left = Value(number: left.number * right.number)
                } else {
                    return left
                }
            }
        }

        private mutating func power() -> Value? {
            guard let base = unary() else { return nil }
            if case .op("^")? = current {
                advance()
                guard let exponent = power() else { return nil }
                return Value(number: pow(base.number, exponent.number))
            }
            return base
        }

        private mutating func unary() -> Value? {
            if case .op("-")? = current {
                advance()
                guard let value = unary() else { return nil }
                return Value(number: -value.number, isPercent: value.isPercent)
            }
            if case .op("+")? = current { advance() }
            guard var value = primary() else { return nil }
            while true {
                if case .percent? = current {
                    advance()
                    value = Value(number: value.number / 100, isPercent: true)
                } else if case .op("!")? = current {
                    advance()
                    guard value.number >= 0, value.number <= 170, value.number == value.number.rounded() else { return nil }
                    value = Value(number: (0...Int(value.number)).dropFirst().reduce(1.0) { $0 * Double($1) })
                } else if case .word(let unit)? = current, unit == "deg" || unit == "degrees" {
                    advance()
                    value = Value(number: value.number * .pi / 180)
                } else {
                    return value
                }
            }
        }

        private mutating func primary() -> Value? {
            switch current {
            case .number(let n)?:
                advance()
                return Value(number: n)
            case .open?:
                advance()
                guard let value = expression(), case .close? = current else { return nil }
                advance()
                return Value(number: value.number)
            case .word(let word)?:
                advance()
                switch word {
                case "pi": return Value(number: .pi)
                case "e": return Value(number: M_E)
                default:
                    guard let function = Self.functions[word], let argument = unary() else { return nil }
                    return Value(number: function(argument.number))
                }
            default:
                return nil
            }
        }

        private static let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "abs": { abs($0) }, "exp": { exp($0) },
            "log": { log10($0) }, "ln": { log($0) },
            "round": { $0.rounded() }, "floor": { floor($0) }, "ceil": { ceil($0) },
            "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
            "cot": { 1 / tan($0) }, "sec": { 1 / cos($0) }, "csc": { 1 / sin($0) },
            "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
            "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
            "asinh": { asinh($0) }, "acosh": { acosh($0) }, "atanh": { atanh($0) },
        ]
    }
}
