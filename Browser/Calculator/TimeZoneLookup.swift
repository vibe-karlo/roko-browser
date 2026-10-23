import Foundation

/// The time somewhere else. "time in istanbul", "london time", "what time is it
/// in nyc", "time in pst", "time diff tokyo", "time in 4 hours", "5pm ldn in sf",
/// "17:00 in tokyo" (your 17:00 there), "time" on its own.
enum TimeZoneLookup {
    static func answer(_ text: String) -> CalculatorAnswer? {
        if text == "time" { return current(in: .current, label: "Here") }
        if let answer = difference(text) ?? later(text) ?? conversion(text) { return answer }

        var place: Substring?
        for prefix in ["what time is it in ", "what time in ", "current time in ", "time in ", "time at ", "time "]
        where text.hasPrefix(prefix) {
            place = text.dropFirst(prefix.count)
            break
        }
        if place == nil, text.hasSuffix(" time") { place = text.dropLast(5) }
        guard let place, let (zone, label) = zone(named: String(place)) else { return nil }
        return current(in: zone, label: label)
    }

    private static func current(in zone: TimeZone, label: String) -> CalculatorAnswer {
        let now = Date.now
        if zone == .current, label == "Here" {
            return CalculatorAnswer(result: clock(now, zone), question: day(now, zone))
        }
        return CalculatorAnswer(result: clock(now, zone), question: "\(label) · \(day(now, zone)) · \(offset(of: zone))")
    }

    /// "time diff paris", "diff tokyo", "time difference new york".
    private static func difference(_ text: String) -> CalculatorAnswer? {
        guard let prefix = ["time difference ", "time diff ", "diff "].first(where: text.hasPrefix),
              let (zone, label) = zone(named: String(text.dropFirst(prefix.count))) else { return nil }
        return CalculatorAnswer(result: offset(of: zone), question: "\(label) · \(clock(.now, zone)) there")
    }

    /// "time in 4 hours", "time in 90 minutes", "time in 2 hours in tokyo".
    private static func later(_ text: String) -> CalculatorAnswer? {
        guard text.hasPrefix("time in "), let match = text.wholeMatch(of: laterPattern),
              let amount = Double(match.1) else { return nil }
        let unit = match.2.hasPrefix("h") ? 3600.0 : 60.0
        var zone = TimeZone.current, label = "Here"
        if let place = match.3, let found = self.zone(named: String(place)) { (zone, label) = found }
        else if match.3 != nil { return nil }
        let date = Date.now.addingTimeInterval(amount * unit)
        return CalculatorAnswer(result: clock(date, zone), question: "\(label) · \(day(date, zone)) · in \(match.1) \(match.2)")
    }

    private static let laterPattern = /time in (\d+(?:\.\d+)?) ?(hours?|hrs?|h|minutes?|mins?|m)(?: in (.+))?/

    /// "5pm ldn in sf", "17:00 london to tokyo", "9am in new york" (your 9am, there).
    private static func conversion(_ text: String) -> CalculatorAnswer? {
        // Cheap checks first: a time ("5pm", "17:00") and a place to put it in.
        guard let first = text.first, first.isNumber,
              text.contains(":") || text.contains("am") || text.contains("pm"),
              text.contains(" in ") || text.contains(" to "),
              let match = text.wholeMatch(of: conversionPattern) else { return nil }
        var hour = Int(match.1) ?? 0
        let minute = match.2.flatMap { Int($0) } ?? 0
        // A bare "5 ldn in sf" is too likely to be something else; ask for am/pm or a colon.
        guard match.2 != nil || match.3 != nil, minute < 60 else { return nil }
        if let meridiem = match.3 {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard hour < 24 else { return nil }

        var fromZone = TimeZone.current, fromLabel = "here"
        if let source = match.4 {
            guard let found = zone(named: String(source)) else { return nil }
            (fromZone, fromLabel) = found
        }
        guard let (toZone, toLabel) = zone(named: String(match.5)) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fromZone
        guard let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: .now) else { return nil }
        let there = clock(start, toZone)
        let dayNote = day(start, toZone) == day(start, fromZone) ? "" : " · \(day(start, toZone))"
        return CalculatorAnswer(result: there + dayNote, question: "\(clock(start, fromZone)) \(fromLabel) in \(toLabel)")
    }

    private static let conversionPattern =
        /(\d{1,2})(?::(\d{2}))? ?(am|pm)?(?: (?:in |at )?(.+?))? (?:in|to) (.+)/

    // MARK: Formatting

    private static func clock(_ date: Date, _ zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    private static func day(_ date: Date, _ zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).day().month(.abbreviated))
    }

    private static func offset(of zone: TimeZone) -> String {
        let now = Date.now
        let hours = Double(zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        if hours == 0 { return "same time as here" }
        return "\(hours > 0 ? "+" : "−")\(Calculator.format(abs(hours), maxFractionDigits: 2)) h from here"
    }

    // MARK: Places

    /// A place, nickname, country or abbreviation to its time zone and a display name.
    static func zone(named raw: String) -> (TimeZone, String)? {
        let name = raw.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard name.count >= 2 else { return nil }
        if let (identifier, label) = aliases[name], let zone = TimeZone(identifier: identifier) {
            return (zone, label)
        }
        if let identifier = cities[name.replacingOccurrences(of: " ", with: "_")], let zone = TimeZone(identifier: identifier) {
            return (zone, String(identifier.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " "))
        }
        if name.count <= 5, name.allSatisfy(\.isLetter), let zone = TimeZone(abbreviation: name.uppercased()) {
            return (zone, name.uppercased())
        }
        return nil
    }

    /// Every city in the time zone database, by its lower-case name. Built once, on first use.
    private static let cities: [String: String] = {
        var table: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            table[city.lowercased()] = identifier
        }
        return table
    }()

    /// Nicknames, cities the database doesn't name, and countries with one time zone
    /// (or one that most people mean).
    private static let aliases: [String: (String, String)] = {
        var table: [String: (String, String)] = [:]
        func add(_ identifier: String, _ label: String, _ names: String...) {
            names.forEach { table[$0] = (identifier, label) }
        }
        add("America/New_York", "New York", "nyc", "ny", "new york city", "manhattan", "brooklyn", "boston",
            "washington", "dc", "washington dc", "miami", "atlanta", "philadelphia", "est", "edt", "et", "eastern")
        add("America/Los_Angeles", "San Francisco", "sf", "san francisco", "bay area", "silicon valley",
            "san jose", "palo alto", "cupertino")
        add("America/Los_Angeles", "Los Angeles", "la", "seattle", "las vegas", "vegas", "san diego", "portland",
            "pst", "pdt", "pt", "pacific")
        add("America/Chicago", "Chicago", "dallas", "houston", "austin", "new orleans", "cst", "cdt", "ct", "central")
        add("America/Denver", "Denver", "salt lake city", "mst", "mdt", "mountain")
        add("America/Toronto", "Toronto", "canada", "ottawa", "montreal")
        add("America/Mexico_City", "Mexico City", "mexico", "cdmx")
        add("America/Sao_Paulo", "São Paulo", "brazil", "rio", "rio de janeiro")
        add("America/Argentina/Buenos_Aires", "Buenos Aires", "argentina", "buenos aires")
        add("America/New_York", "New York", "usa", "us", "america", "united states")
        add("Europe/London", "London", "ldn", "uk", "england", "britain", "great britain", "united kingdom",
            "manchester", "edinburgh", "scotland")
        add("Europe/Dublin", "Dublin", "ireland")
        add("Europe/Zagreb", "Zagreb", "croatia", "hrvatska", "split", "rijeka", "osijek", "zadar", "dubrovnik", "pula")
        add("Europe/Belgrade", "Belgrade", "serbia", "srbija", "beograd", "novi sad")
        add("Europe/Sarajevo", "Sarajevo", "bosnia", "bih", "bosnia and herzegovina", "mostar", "banja luka")
        add("Europe/Ljubljana", "Ljubljana", "slovenia")
        add("Europe/Podgorica", "Podgorica", "montenegro")
        add("Europe/Skopje", "Skopje", "macedonia", "north macedonia")
        add("Europe/Tirane", "Tirana", "albania", "tirana")
        add("Europe/Istanbul", "Istanbul", "turkey", "turkiye", "türkiye", "ankara", "antalya")
        add("Europe/Berlin", "Berlin", "germany", "munich", "frankfurt", "hamburg", "cologne")
        add("Europe/Paris", "Paris", "france", "lyon", "nice")
        add("Europe/Madrid", "Madrid", "spain", "barcelona", "valencia")
        add("Europe/Rome", "Rome", "italy", "milan", "venice", "florence", "naples")
        add("Europe/Amsterdam", "Amsterdam", "netherlands", "holland", "rotterdam")
        add("Europe/Brussels", "Brussels", "belgium")
        add("Europe/Zurich", "Zurich", "switzerland", "geneva", "bern")
        add("Europe/Vienna", "Vienna", "austria", "wien", "graz", "salzburg")
        add("Europe/Prague", "Prague", "czechia", "czech republic", "praha")
        add("Europe/Warsaw", "Warsaw", "poland", "krakow")
        add("Europe/Budapest", "Budapest", "hungary")
        add("Europe/Bratislava", "Bratislava", "slovakia")
        add("Europe/Bucharest", "Bucharest", "romania")
        add("Europe/Sofia", "Sofia", "bulgaria")
        add("Europe/Athens", "Athens", "greece")
        add("Europe/Lisbon", "Lisbon", "portugal", "porto")
        add("Europe/Stockholm", "Stockholm", "sweden")
        add("Europe/Oslo", "Oslo", "norway")
        add("Europe/Copenhagen", "Copenhagen", "denmark")
        add("Europe/Helsinki", "Helsinki", "finland")
        add("Europe/Kyiv", "Kyiv", "ukraine", "kyiv", "kiev")
        add("Europe/Moscow", "Moscow", "russia", "st petersburg", "saint petersburg")
        add("Atlantic/Reykjavik", "Reykjavik", "iceland")
        add("Asia/Jerusalem", "Jerusalem", "israel", "tel aviv")
        add("Asia/Dubai", "Dubai", "uae", "emirates", "abu dhabi")
        add("Asia/Riyadh", "Riyadh", "saudi arabia")
        add("Asia/Qatar", "Doha", "qatar", "doha")
        add("Africa/Cairo", "Cairo", "egypt")
        add("Africa/Johannesburg", "Johannesburg", "south africa", "cape town")
        add("Asia/Kolkata", "India", "india", "delhi", "new delhi", "mumbai", "bangalore", "bengaluru", "ist")
        add("Asia/Shanghai", "China", "china", "beijing", "shenzhen")
        add("Asia/Hong_Kong", "Hong Kong", "hk")
        add("Asia/Taipei", "Taipei", "taiwan")
        add("Asia/Tokyo", "Tokyo", "japan", "osaka", "kyoto", "jst")
        add("Asia/Seoul", "Seoul", "korea", "south korea")
        add("Asia/Bangkok", "Bangkok", "thailand", "phuket")
        add("Asia/Ho_Chi_Minh", "Ho Chi Minh City", "vietnam", "saigon", "hanoi")
        add("Asia/Jakarta", "Jakarta", "indonesia")
        add("Asia/Makassar", "Bali", "bali")
        add("Asia/Manila", "Manila", "philippines")
        add("Asia/Singapore", "Singapore", "singapore")
        add("Australia/Sydney", "Sydney", "australia", "aest")
        add("Pacific/Auckland", "Auckland", "new zealand", "nz", "wellington")
        add("UTC", "UTC", "utc", "gmt", "zulu")
        return table
    }()
}
