import CoreLocation
import Foundation

/// A paid street-parking zone, paid for by sending the car's registration to
/// the zone's number (m-parking). One text buys `ticketMinutes`.
nonisolated struct ParkingZone: Hashable, Identifiable, Sendable {
    /// As in the city's data file: "0", "1".
    let code: String
    /// As on the signs: "Zona 0", "Zona I".
    let name: String
    let number: String
    let pricePerHour: Double
    /// Paid parking allowed per day, in minutes (Osijek's zone 0: three hours).
    var maxMinutesPerDay: Int?
    var ticketMinutes = 60

    var id: String { code }

    var price: String {
        pricePerHour.formatted(.currency(code: "EUR").locale(Locale(identifier: "hr_HR")))
    }
}

/// A city roko pays parking in. Only these: elsewhere the parking answer
/// doesn't appear at all.
nonisolated struct ParkingCity: Identifiable, Sendable {
    let id: String
    let name: String
    let zones: [ParkingZone]
    /// Roughly where the city's paid zones are: a quick "not here" before any maths.
    let bounds: (south: Double, west: Double, north: Double, east: Double)
    /// Charging hours by weekday (Calendar numbering, 1 is Sunday): from and until, in hours.
    let hours: [Int: (from: Int, until: Int)]
    /// Spots with a free start, as the operator posts them: said under the zone.
    var note: String?

    func zone(_ code: String) -> ParkingZone? { zones.first { $0.code == code } }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (bounds.south...bounds.north).contains(coordinate.latitude) && (bounds.west...bounds.east).contains(coordinate.longitude)
    }

    /// When charging stops today, if it's on now; nil when parking is free now
    /// (evenings, Sundays, public holidays).
    func chargingEnds(after date: Date, calendar: Calendar = .current) -> Date? {
        let weekday = calendar.component(.weekday, from: date)
        guard !CroatianHolidays.isHoliday(date, calendar: calendar), let span = hours[weekday] else { return nil }
        let day = calendar.startOfDay(for: date)
        guard let from = calendar.date(byAdding: .hour, value: span.from, to: day),
              let until = calendar.date(byAdding: .hour, value: span.until, to: day),
              date >= from, date < until else { return nil }
        return until
    }

    /// "Mon–Fri 7–21, Sat 7–15", for saying when it's free.
    var hoursLine: String {
        let weekday = hours[2].map { "Mon–Fri \($0.from)–\($0.until)" }
        let saturday = hours[7].map { "Sat \($0.from)–\($0.until)" }
        return [weekday, saturday].compactMap { $0 }.joined(separator: ", ")
    }

    // Osijek: GPP Osijek's price list and m-parking numbers (gpp-osijek.com,
    // September 2026). Zone II starts in November 2026.
    static let osijek = ParkingCity(
        id: "osijek", name: "Osijek",
        zones: [
            ParkingZone(code: "0", name: "Zona 0", number: "708310", pricePerHour: 1.5, maxMinutesPerDay: 180),
            ParkingZone(code: "1", name: "Zona I", number: "708311", pricePerHour: 1.0),
        ],
        bounds: (45.53, 18.62, 45.58, 18.75),
        hours: [2: (7, 21), 3: (7, 21), 4: (7, 21), 5: (7, 21), 6: (7, 21), 7: (7, 15)],
        note: "By the market (Trg Ljudevita Gaja, Sudski prolaz) the first hour is free, 7–13.")

    static let all = [osijek]

    static func with(id: String) -> ParkingCity? { all.first { $0.id == id } }
}

/// Days parking isn't charged: Croatia's public holidays.
nonisolated enum CroatianHolidays {
    static func isHoliday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }
        let fixed: Set<[Int]> = [[1, 1], [1, 6], [5, 1], [5, 30], [6, 22], [8, 5], [8, 15], [11, 1], [11, 18], [12, 25], [12, 26]]
        if fixed.contains([month, day]) { return true }
        // Easter Monday and Corpus Christi move with Easter.
        guard let easter = easterSunday(year, calendar: calendar) else { return false }
        let today = calendar.startOfDay(for: date)
        return [1, 60].contains { calendar.date(byAdding: .day, value: $0, to: easter) == today }
    }

    /// The Gregorian computus (Meeus/Jones/Butcher).
    static func easterSunday(_ year: Int, calendar: Calendar) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

/// Where you are, in a zone: the nearest paid parking area from the city's
/// map (Resources/Parking/<city>.json, from OpenStreetMap; Scripts/build_parking.py).
nonisolated struct ParkingMatch: Sendable {
    let city: ParkingCity
    /// Nearest first. More than one when another zone is nearly as close:
    /// at a border, a wrong guess means a fine, so you choose.
    let zones: [ParkingZone]
    /// Metres to the nearest paid area; 0 inside one.
    let distance: Double
}

nonisolated enum ParkingZones {
    private struct Area: Decodable {
        let z: String
        let p: [[Double]]
    }

    private struct File: Decodable {
        let areas: [Area]
    }

    /// Each city's areas, read once (tens of KB).
    private static let areas: [String: [Area]] = {
        var all: [String: [Area]] = [:]
        for city in ParkingCity.all {
            guard let url = Bundle.main.url(forResource: city.id, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data) else { continue }
            all[city.id] = file.areas
        }
        return all
    }()

    /// Within this of a paid area counts as parked in it: GPS is off by a few
    /// metres in town, more between tall buildings.
    static let reach = 60.0
    /// Another zone this much further than the nearest still gets offered.
    static let border = 25.0

    static func match(_ location: CLLocation) -> ParkingMatch? {
        let here = location.coordinate
        guard let city = ParkingCity.all.first(where: { $0.contains(here) }), let areas = areas[city.id] else { return nil }
        let reach = Self.reach + min(max(location.horizontalAccuracy, 0), 40)
        var nearest: [String: Double] = [:]
        for area in areas {
            let distance = Self.distance(from: here, to: area.p)
            guard distance <= reach else { continue }
            nearest[area.z] = min(nearest[area.z] ?? .infinity, distance)
        }
        guard let best = nearest.values.min() else { return nil }
        let zones = nearest.filter { $0.value <= best + border }
            .sorted { $0.value < $1.value }
            .compactMap { city.zone($0.key) }
        guard !zones.isEmpty else { return nil }
        return ParkingMatch(city: city, zones: zones, distance: best)
    }

    /// Metres from a point to a polygon: 0 inside, else to its nearest edge.
    /// Flat maths is plenty across a town (a few hundred metres).
    private static func distance(from point: CLLocationCoordinate2D, to polygon: [[Double]]) -> Double {
        let metresPerDegree = 111_320.0
        let scaleX = cos(point.latitude * .pi / 180) * metresPerDegree
        let xy = polygon.map { (x: ($0[1] - point.longitude) * scaleX, y: ($0[0] - point.latitude) * metresPerDegree) }
        var inside = false
        var best = Double.infinity
        for i in xy.indices {
            let a = xy[i], b = xy[(i + 1) % xy.count]
            if (a.y > 0) != (b.y > 0), 0 < (b.x - a.x) * (0 - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, -(a.x * dx + a.y * dy) / max(dx * dx + dy * dy, 1e-9)))
            best = min(best, hypot(a.x + t * dx, a.y + t * dy))
        }
        return inside ? 0 : best
    }
}
