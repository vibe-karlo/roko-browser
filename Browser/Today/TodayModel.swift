import BackgroundTasks
import CoreLocation
import Foundation

/// What Today shows, and when it's fetched. The last of it is kept on disk,
/// so the page opens at once with what was there and freshens behind it:
/// in the morning before you look (iOS wakes roko in the background), when
/// you open it more than an hour after the last time, or when you pull down.
/// Nothing is fetched while Today isn't being looked at or prepared.
@MainActor
@Observable
final class TodayModel {
    static let shared = TodayModel()

    private(set) var weather: TodayWeather?
    private(set) var top: [NewsStory] = []
    /// A section per followed page, then per topic.
    private(set) var followed: [FollowedSection] = []
    private(set) var events: [TodayEvent] = []
    private(set) var refreshedAt: Date?
    private(set) var isRefreshing = false

    /// After this long, opening Today freshens it.
    private static let staleAfter: TimeInterval = 3600

    private init() {
        load()
    }

    var newsSites: [NewsSite] { NewsSite.chosen }

    // MARK: Refreshing

    /// On opening: the calendar (instant, it's on the phone) always; the rest if stale.
    func appeared() {
        events = TodayCalendar.events()
        let stale = refreshedAt.map { Date.now.timeIntervalSince($0) > Self.staleAfter || !Calendar.current.isDateInToday($0) } ?? true
        if stale { Task { await refresh() } }
    }

    /// From pull to refresh: in a task of its own, so the gesture ending
    /// (which cancels its own task) can't cancel the requests halfway.
    func refreshFromPull() async {
        await Task { await refresh() }.value
    }

    func refresh(inBackground: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let started = CFAbsoluteTimeGetCurrent()

        let sources = NewsSite.chosen
        let topics = NewsTopics.chosen
        // Topics are looked for in the major Croatian feeds too, not only your own.
        let pool = topics.isEmpty ? [] : TodayNews.topicPool.filter { extra in !sources.contains { $0.id == extra.id } }
        async let weather = freshWeather(inBackground: inBackground)
        async let read = TodayNews.stories(of: sources + pool)
        let (newWeather, byID) = await (weather, read)
        if let newWeather { self.weather = newWeather }

        // Whole sites compete for Top stories; each followed page keeps its own section.
        let siteStories = TodayNews.recent(sources.filter { !$0.isSection }.flatMap { byID[$0.id] ?? [] })
        var picked: [NewsStory] = []
        // Nothing came back (offline, say): what was there stays.
        if !siteStories.isEmpty {
            // The newest first while the model picks the front page.
            if top.isEmpty { top = Array(siteStories.prefix(6)) }
            picked = await TodayNews.top(siteStories)
            top = picked
        } else if sources.allSatisfy(\.isSection) {
            top = []
        }
        var sections: [FollowedSection] = sources.filter(\.isSection).compactMap { source in
            let stories = byID[source.id] ?? []
            if stories.isEmpty { return followed.first { $0.id == source.id } }  // keep the last when a read fails
            return FollowedSection(id: source.id, title: source.title, host: source.host,
                                   stories: TodayNews.varied(TodayNews.recent(stories, hours: 72), count: 4, perSite: 4))
        }
        let everything = byID.values.flatMap { $0 }
        for topic in topics {
            let stories = await TodayNews.about(topic, in: everything)
            sections.append(FollowedSection(id: "topic:" + topic, title: topic, host: nil, stories: stories))
        }
        followed = sections
        let newStories = everything

        if !inBackground { events = TodayCalendar.events() }
        // Only a refresh that brought something counts as one.
        if newWeather != nil || !newStories.isEmpty {
            refreshedAt = .now
            save()
        }
        if LaunchClock.isEnabled {
            print(String(format: "TODAY refreshed in %.2fs: weather=%@ stories=%d top=%d", CFAbsoluteTimeGetCurrent() - started,
                         newWeather == nil ? "none" : "yes", newStories.count, picked.count))
        }
    }

    /// The weather where you are. In the background there's no asking where
    /// that is: the last place found stands in.
    private func freshWeather(inBackground: Bool) async -> TodayWeather? {
        var coordinate = Self.lastCoordinate
        var place = UserDefaults.standard.string(forKey: "today.place")
        if !inBackground, let location = await TodayLocation.shared.current() {
            coordinate = location.coordinate
            place = await TodayLocation.placeName(for: location) ?? place
            UserDefaults.standard.set([location.coordinate.latitude, location.coordinate.longitude], forKey: "today.coordinate")
            UserDefaults.standard.set(place, forKey: "today.place")
        }
        guard let coordinate else { return nil }
        return try? await TodayWeather.fetch(at: coordinate, place: place)
    }

    private static var lastCoordinate: CLLocationCoordinate2D? {
        guard let pair = UserDefaults.standard.array(forKey: "today.coordinate") as? [Double], pair.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
    }

    /// Sources or topics changed: show the new set's stories.
    func sitesChanged() {
        top = []
        followed = []
        Task { await refresh() }
    }

    // MARK: Opening each morning

    static let openKey = "today.openEachMorning"
    private static let shownKey = "today.lastShown"

    /// The first time roko comes up on a new day, from 4 in the morning: Today first.
    static func shouldOpenNow() -> Bool {
        guard UserDefaults.standard.object(forKey: openKey) as? Bool ?? true else { return false }
        let calendar = Calendar.current
        guard calendar.component(.hour, from: .now) >= 4 else { return false }
        if let shown = UserDefaults.standard.object(forKey: shownKey) as? Date, calendar.isDateInToday(shown) { return false }
        return true
    }

    static func markShown() {
        UserDefaults.standard.set(Date.now, forKey: shownKey)
    }

    // MARK: Prepared in the background

    static let taskID = "com.growthstudio.roko.today"

    /// Asks iOS to wake roko a little before the morning, to have Today ready.
    static func scheduleMorningRefresh() {
        guard UserDefaults.standard.object(forKey: openKey) as? Bool ?? true else { return }
        let calendar = Calendar.current
        let morning = calendar.nextDate(after: .now, matching: DateComponents(hour: 5, minute: 30), matchingPolicy: .nextTime)
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = morning
        Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
    }

    // MARK: Kept on disk

    private struct Saved: Codable {
        var weather: TodayWeather?
        var top: [NewsStory]
        var followed: [FollowedSection]?
        var refreshedAt: Date?
    }

    private static var file: URL { URL.applicationSupportDirectory.appending(path: "today.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        weather = saved.weather
        top = saved.top
        followed = saved.followed ?? []
        refreshedAt = saved.refreshedAt
    }

    private func save() {
        let saved = Saved(weather: weather, top: top, followed: followed, refreshedAt: refreshedAt)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
