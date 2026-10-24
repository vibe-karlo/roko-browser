import EventKit
import Foundation

/// Today's events from the calendars on this iPhone (iCloud, Google, Outlook,
/// whatever is added in Settings → Calendar), read here and never sent anywhere.
nonisolated struct TodayEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
}

@MainActor
enum TodayCalendar {
    private static let store = EKEventStore()

    static var isAllowed: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var wasAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    /// Asks once; afterwards the answer stands until changed in iOS Settings.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// What's left of today: events that haven't ended, all-day ones first.
    static func events() -> [TodayEvent] {
        guard isAllowed else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.isAllDay || $0.endDate > .now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(8)
            .map { event in
                TodayEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event",
                           start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                           location: event.location.flatMap { $0.isEmpty ? nil : $0 })
            }
    }
}
