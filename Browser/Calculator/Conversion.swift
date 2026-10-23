import Foundation

/// "5 km to mi", "100f", "72 kg in lb", "$40 in eur", "usd 10 in rsd/hrk/eur",
/// "2rem in px", "145 mins to timespan". Units come from Foundation's
/// Measurement types, so the conversion factors are Apple's. Without a target
/// ("5 km"), it converts to the usual counterpart.
enum Conversion {
    static func answer(_ text: String) -> CalculatorAnswer? {
        // Try "<amount> <unit> <connector> <unit>", splitting at the last connector.
        // " u " is Croatian, Serbian and Bosnian for "in": "100 eur u rsd".
        for connector in [" to ", " in ", " u ", " as ", " into ", " = ", " → ", " -> "] {
            guard let range = text.range(of: connector, options: .backwards) else { continue }
            let left = String(text[..<range.lowerBound])
            let right = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let (amount, from) = quantity(left) else { continue }
            if let answer = convert(amount, from, to: right, question: text) { return answer }
            if let answer = convertToMany(amount, from, targets: right) { return answer }
        }
        guard let (amount, from) = quantity(text) else { return nil }
        return convert(amount, from, to: nil, question: text)
    }

    /// "10 usd in rsd/hrk/eur" or "in rsd, hrk and eur": every answer in one line.
    private static func convertToMany(_ amount: Double, _ from: Unit, targets: String) -> CalculatorAnswer? {
        let parts = targets
            .replacingOccurrences(of: " and ", with: ",")
            .split(whereSeparator: { $0 == "/" || $0 == "," || $0 == "&" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1, parts.count <= 6 else { return nil }
        let answers = parts.compactMap { convert(amount, from, to: $0, question: "") }
        guard answers.count == parts.count else { return nil }
        let source: String
        switch from {
        case .measure(let unit): source = "\(Calculator.format(amount, maxFractionDigits: 4)) \(unit.symbol)"
        case .currency(let code): source = money(amount, code) + rateNote(codes: [code] + parts.map { $0.uppercased() })
        }
        return CalculatorAnswer(result: answers.map(\.result).joined(separator: " · "), question: source)
    }

    // MARK: Parsing

    private enum Unit {
        case measure(Dimension)
        case currency(String)
    }

    /// Splits "12.5km", "100 °F", "$40", "3*4 m" into an amount and a unit.
    private static func quantity(_ text: String) -> (Double, Unit)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        // Leading currency symbol: "$40", "€ 12.50".
        if let first = text.first, let code = symbols[first] {
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            if let amount = Expression.evaluate(rest) { return (amount, .currency(code)) }
        }
        // Leading currency code: "usd 10", "eur1k".
        if text.count > 3, let next = text.dropFirst(3).first, !next.isLetter {
            let code = text.prefix(3).uppercased()
            if code.allSatisfy(\.isLetter), CurrencyRates.shared.knows(code),
               let amount = Expression.evaluate(String(text.dropFirst(3))) {
                return (amount, .currency(code))
            }
        }
        // Trailing unit: the longest alias the text ends with.
        for alias in sortedAliases where text.hasSuffix(alias) {
            let amountText = text.dropLast(alias.count).trimmingCharacters(in: .whitespaces)
            // "5 in" needs the space; "5in" too, but not "login".
            if let last = amountText.last, last.isLetter { continue }
            guard !amountText.isEmpty, let amount = Expression.evaluate(amountText), let unit = unit(alias) else { continue }
            return (amount, unit)
        }
        return nil
    }

    private static func unit(_ word: String) -> Unit? {
        let word = word.trimmingCharacters(in: .whitespaces)
        if let dimension = units[word] { return .measure(dimension) }
        if let first = word.first, word.count == 1, let code = symbols[first] { return .currency(code) }
        if let code = currencyWords[word] { return .currency(code) }
        if word.count == 3, CurrencyRates.shared.knows(word.uppercased()) { return .currency(word.uppercased()) }
        return nil
    }

    // MARK: Converting

    private static func convert(_ amount: Double, _ from: Unit, to targetText: String?, question: String) -> CalculatorAnswer? {
        switch from {
        case .measure(let unit):
            if let targetText, timespanWords.contains(targetText), unit is UnitDuration {
                let seconds = Measurement(value: amount, unit: unit).converted(to: UnitDuration.seconds).value
                return CalculatorAnswer(result: timespan(seconds),
                                        question: "\(Calculator.format(amount, maxFractionDigits: 4)) \(unit.symbol)")
            }
            let target: Dimension
            if let targetText {
                guard case .measure(let t)? = self.unit(targetText), type(of: t) == type(of: unit) else { return nil }
                target = t
            } else {
                guard let t = counterpart[unit.symbol] else { return nil }
                target = t
            }
            let value = Measurement(value: amount, unit: unit).converted(to: target).value
            return CalculatorAnswer(result: "\(Calculator.format(value, maxFractionDigits: 4)) \(target.symbol)",
                                    question: "\(Calculator.format(amount, maxFractionDigits: 4)) \(unit.symbol) in \(target.symbol)")

        case .currency(let code):
            let target: String
            if let targetText {
                guard case .currency(let t)? = self.unit(targetText) else { return nil }
                target = t
            } else {
                let local = Locale.current.currency?.identifier ?? "USD"
                target = code == local ? (local == "USD" ? "EUR" : "USD") : local
            }
            guard let value = CurrencyRates.shared.convert(amount, from: code, to: target) else { return nil }
            return CalculatorAnswer(result: money(value, target),
                                    question: "\(money(amount, code)) in \(target)" + rateNote(codes: [code, target]))
        }
    }

    /// Where the rate comes from: the euro's fixed conversion rate, or the day's market rate.
    private static func rateNote(codes: [String]) -> String {
        let rates = CurrencyRates.shared
        let market = codes.filter { $0 != "EUR" && !rates.isFixed($0) }
        if market.isEmpty { return " · fixed euro rate" }
        return rates.dateLabel.isEmpty ? "" : " · rate of \(rates.dateLabel)"
    }

    private static let timespanWords: Set<String> = ["timespan", "time span", "duration", "hours and minutes", "hh:mm"]

    /// 8700 → "2 h 25 min"; days and seconds only when they're there.
    private static func timespan(_ seconds: Double) -> String {
        var rest = Int(seconds.rounded())
        var parts: [String] = []
        for (size, label) in [(86_400, "d"), (3_600, "h"), (60, "min"), (1, "s")] where rest >= size {
            parts.append("\(rest / size) \(label)")
            rest %= size
        }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }

    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        return formatter
    }()

    private static func money(_ value: Double, _ code: String) -> String {
        moneyFormatter.currencyCode = code
        return moneyFormatter.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }

    // MARK: Tables

    private static let symbols: [Character: String] = [
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₺": "TRY", "₽": "RUB",
    ]

    private static let currencyWords: [String: String] = [
        "dollar": "USD", "dollars": "USD", "bucks": "USD", "euro": "EUR", "euros": "EUR", "eura": "EUR",
        "yen": "JPY", "franc": "CHF", "francs": "CHF", "rupee": "INR", "rupees": "INR",
        "kuna": "HRK", "kune": "HRK", "kn": "HRK", "dinar": "RSD", "dinars": "RSD", "dinara": "RSD", "din": "RSD",
        "lira": "TRY", "yuan": "CNY", "rmb": "CNY", "won": "KRW", "zloty": "PLN", "forint": "HUF",
        "rubles": "RUB", "ruble": "RUB", "rand": "ZAR", "real": "BRL", "reais": "BRL", "dirham": "AED",
        "bitcoin": "BTC", "bitcoins": "BTC", "ether": "ETH", "ethereum": "ETH", "marka": "BAM", "konvertibilna marka": "BAM",
    ]

    private static let units: [String: Dimension] = {
        var table: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { names.forEach { table[$0] = unit } }
        add(UnitLength.millimeters, "mm", "millimeter", "millimeters")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters")
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.inches, "in", "inch", "inches", "\"")
        add(UnitLength.feet, "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitLength.nauticalMiles, "nmi")
        // CSS: 96 px to the inch, 16 px to the rem.
        let pixel = 0.0254 / 96
        add(UnitLength(symbol: "px", converter: UnitConverterLinear(coefficient: pixel)), "px", "pixel", "pixels")
        add(UnitLength(symbol: "rem", converter: UnitConverterLinear(coefficient: pixel * 16)), "rem", "em")
        add(UnitMass.milligrams, "mg")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.kilograms, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add(UnitMass.metricTons, "t", "tonne", "tonnes")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitMass.stones, "st", "stone", "stones")
        add(UnitTemperature.celsius, "c", "°c", "celsius")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit")
        // Not "k": "10k" means ten thousand.
        add(UnitTemperature.kelvin, "kelvin")
        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters")
        add(UnitVolume.centiliters, "cl")
        add(UnitVolume.deciliters, "dl")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitVolume.quarts, "qt", "quart", "quarts")
        add(UnitVolume.pints, "pt", "pint", "pints")
        add(UnitVolume.cups, "cup", "cups")
        add(UnitVolume.fluidOunces, "floz", "fl oz")
        add(UnitVolume.tablespoons, "tbsp")
        add(UnitVolume.teaspoons, "tsp")
        add(UnitArea.squareMeters, "m2", "m²", "sqm")
        add(UnitArea.squareKilometers, "km2", "km²")
        add(UnitArea.squareFeet, "ft2", "ft²", "sqft")
        add(UnitArea.acres, "acre", "acres")
        add(UnitArea.hectares, "ha", "hectare", "hectares")
        add(UnitSpeed.kilometersPerHour, "km/h", "kmh", "kph")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.metersPerSecond, "m/s")
        // Not "kn": that's kuna.
        add(UnitSpeed.knots, "knot", "knots", "kt")
        add(UnitInformationStorage.bytes, "b", "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "kb")
        add(UnitInformationStorage.megabytes, "mb")
        add(UnitInformationStorage.gigabytes, "gb")
        add(UnitInformationStorage.terabytes, "tb")
        add(UnitDuration.milliseconds, "ms")
        add(UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")
        // Foundation's durations stop at hours.
        add(UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "d", "day", "days")
        add(UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "wk", "week", "weeks")
        return table
    }()

    private static let sortedAliases: [String] = {
        (Array(units.keys) + Array(currencyWords.keys)
            + (CurrencyRates.codes + CurrencyRates.fixed.keys).map { $0.lowercased() })
            .sorted { $0.count > $1.count }
    }()

    /// What "5 km" (no target) converts to.
    private static let counterpart: [String: Dimension] = [
        UnitLength.kilometers.symbol: UnitLength.miles, UnitLength.miles.symbol: UnitLength.kilometers,
        UnitLength.meters.symbol: UnitLength.feet, UnitLength.feet.symbol: UnitLength.meters,
        UnitLength.centimeters.symbol: UnitLength.inches, UnitLength.inches.symbol: UnitLength.centimeters,
        UnitLength.yards.symbol: UnitLength.meters,
        UnitMass.kilograms.symbol: UnitMass.pounds, UnitMass.pounds.symbol: UnitMass.kilograms,
        UnitMass.grams.symbol: UnitMass.ounces, UnitMass.ounces.symbol: UnitMass.grams,
        UnitTemperature.celsius.symbol: UnitTemperature.fahrenheit,
        UnitTemperature.fahrenheit.symbol: UnitTemperature.celsius,
        UnitTemperature.kelvin.symbol: UnitTemperature.celsius,
        UnitVolume.liters.symbol: UnitVolume.gallons, UnitVolume.gallons.symbol: UnitVolume.liters,
        UnitVolume.milliliters.symbol: UnitVolume.fluidOunces, UnitVolume.fluidOunces.symbol: UnitVolume.milliliters,
        UnitVolume.cups.symbol: UnitVolume.milliliters,
        UnitSpeed.kilometersPerHour.symbol: UnitSpeed.milesPerHour,
        UnitSpeed.milesPerHour.symbol: UnitSpeed.kilometersPerHour,
        UnitSpeed.knots.symbol: UnitSpeed.kilometersPerHour,
        UnitArea.squareMeters.symbol: UnitArea.squareFeet, UnitArea.squareFeet.symbol: UnitArea.squareMeters,
        UnitArea.hectares.symbol: UnitArea.acres, UnitArea.acres.symbol: UnitArea.hectares,
        "px": units["rem"]!, "rem": units["px"]!,
    ]
}
