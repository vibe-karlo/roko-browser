import CoreLocation
import Foundation
import MapKit

/// Today's weather from Open-Meteo: free, no account, no key, from roughly
/// where you are (CC BY 4.0, credited on the page). Apple's own weather
/// service needs the paid developer program.
nonisolated struct TodayWeather: Codable, Equatable, Sendable {
    struct Hour: Codable, Equatable, Sendable, Identifiable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        let rainChance: Int
        var id: Date { time }
    }

    let place: String?
    let temperature: Double
    /// What it feels like, with wind and humidity; nil in weather saved before it was fetched.
    var feelsLike: Double? = nil
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let rainChance: Int
    /// The next hours, from now on.
    let hours: [Hour]
    let fetchedAt: Date

    var condition: String { Self.condition(code) }
    var glyph: String { Self.glyph(code, isDay: isDay) }

    /// "Feels like 8°, 6° to 11°, rain 90%": the day in one short line.
    var dayLine: String {
        var parts: [String] = []
        if let feelsLike, Int(feelsLike.rounded()) != Int(temperature.rounded()) {
            parts.append("Feels like \(Int(feelsLike.rounded()))°")
        }
        parts.append("\(Int(low.rounded()))° to \(Int(high.rounded()))°")
        if rainChance >= 30 { parts.append("rain \(rainChance)%") }
        return parts.joined(separator: ", ")
    }

    /// WMO weather codes, as Open-Meteo reports them.
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorms"
        default: "Mixed"
        }
    }

    /// The Phosphor icon for a code (assets "phosphor/wx-…").
    static func glyph(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0, 1: isDay ? "wx-clear" : "wx-clear-night"
        case 2: isDay ? "wx-partly" : "wx-partly-night"
        case 3: "wx-cloudy"
        case 45, 48: "wx-fog"
        case 51...67, 80...82: "wx-rain"
        case 71...77, 85, 86: "wx-snow"
        case 95...99: "wx-storm"
        default: "wx-cloudy"
        }
    }

    // MARK: Fetching

    static func fetch(at coordinate: CLLocationCoordinate2D, place: String?) async throws -> TodayWeather {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let raw = try JSONDecoder().decode(Raw.self, from: data)

        // Times come in the place's own zone, without an offset: add it.
        let zone = TimeZone(secondsFromGMT: raw.utc_offset_seconds) ?? .current
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm"
        parse.timeZone = zone
        parse.locale = Locale(identifier: "en_US_POSIX")
        let now = Date.now
        var hours: [Hour] = []
        for index in raw.hourly.time.indices {
            guard let time = parse.date(from: raw.hourly.time[index]),
                  time > now.addingTimeInterval(-3_600), hours.count < 12 else { continue }
            hours.append(Hour(time: time, temperature: raw.hourly.temperature_2m[index], code: raw.hourly.weather_code[index],
                              isDay: raw.hourly.is_day[index] == 1, rainChance: raw.hourly.precipitation_probability[index] ?? 0))
        }
        return TodayWeather(place: place, temperature: raw.current.temperature_2m,
                            feelsLike: raw.current.apparent_temperature, code: raw.current.weather_code,
                            isDay: raw.current.is_day == 1, high: raw.daily.temperature_2m_max.first ?? raw.current.temperature_2m,
                            low: raw.daily.temperature_2m_min.first ?? raw.current.temperature_2m,
                            rainChance: raw.daily.precipitation_probability_max.first.flatMap { $0 } ?? 0,
                            hours: hours, fetchedAt: now)
    }

    private struct Raw: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double?
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let weather_code: [Int]
            let precipitation_probability: [Int?]
            let is_day: [Int]
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int?]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }
}

/// Where you are, roughly: a town is enough for the weather. Asked for once;
/// the last place found is kept, so a later refresh doesn't need to ask again.
@MainActor
final class TodayLocation: NSObject, CLLocationManagerDelegate {
    static let shared = TodayLocation()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    var hasAsked: Bool { manager.authorizationStatus != .notDetermined }

    /// The latest place, asking for permission the first time.
    func current() async -> CLLocation? {
        if isDenied { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            // Never hang a refresh on a fix that doesn't come.
            Task {
                try? await Task.sleep(for: .seconds(8))
                self.finish(nil)
            }
        }
    }

    /// The town's name, for the weather line.
    static func placeName(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try? await request.mapItems
        return items?.first?.addressRepresentations?.cityName
    }

    private func finish(_ location: CLLocation?) {
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                if !waiting.isEmpty { self.manager.requestLocation() }
            case .denied, .restricted:
                finish(nil)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { finish(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}

/// A town chosen for the weather in place of where you are, found by name
/// with Open-Meteo's geocoding (free, no key, like the forecast).
nonisolated struct WeatherPlace: Codable, Equatable, Hashable, Sendable, Identifiable {
    let name: String
    /// Region and country, to tell two Springfields apart.
    let detail: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(latitude),\(longitude)" }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    private static let key = "today.weatherPlace"

    /// The chosen town, or nil for where you are.
    static var fixed: WeatherPlace? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
    }

    static func search(_ text: String) async -> [WeatherPlace] {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return [] }
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "8"),
                            .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en")]
        guard let (data, _) = try? await URLSession.shared.data(from: parts.url!),
              let found = try? JSONDecoder().decode(Found.self, from: data) else { return [] }
        // Villages share their town's name and region: the biggest (listed first) stands for them.
        var seen = Set<String>()
        return (found.results ?? []).compactMap { result in
            let place = WeatherPlace(name: result.name, detail: [result.admin1, result.country].compactMap { $0 }.joined(separator: ", "),
                                     latitude: result.latitude, longitude: result.longitude)
            return seen.insert(place.name + "|" + place.detail).inserted ? place : nil
        }
        .prefix(5)
        .map { $0 }
    }

    private struct Found: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }
}
