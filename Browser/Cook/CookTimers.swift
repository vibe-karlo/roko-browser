import AlarmKit
import SwiftUI

/// The timers started from Cook Mode. They're real alarms: iOS counts them down on
/// the Lock Screen and in the Dynamic Island and rings through silent mode and
/// Focus, whether or not roko is still open. The list here is only to show them,
/// kept so they're still there to call off if roko was closed meanwhile.
@MainActor
@Observable
final class CookTimers {
    static let shared = CookTimers()

    struct Timer: Identifiable, Equatable, Codable {
        let id: UUID
        let seconds: Int
        let recipe: String
        let step: Int
        let endsAt: Date
        var isRinging = false
    }

    private static let key = "cook.timers"
    private(set) var running: [Timer] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(running), forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Timer].self, from: $0) } ?? []
        let alarms = (try? AlarmManager.shared.alarms.map(\.id)) ?? []
        running = saved.filter { alarms.contains($0.id) }
        Task {
            for await alarms in AlarmManager.shared.alarmUpdates {
                let states = Dictionary(alarms.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
                running = running.compactMap { timer in
                    guard let state = states[timer.id] else { return nil }
                    var timer = timer
                    timer.isRinging = state == .alerting
                    return timer
                }
            }
        }
    }

    func isRunning(seconds: Int, step: Int, recipe: String) -> Bool {
        running.contains { $0.seconds == seconds && $0.step == step && $0.recipe == recipe }
    }

    /// Nil when it started, or what to tell the cook when it couldn't.
    func start(seconds: Int, step: Int, recipe: String) async -> String? {
        guard !isRunning(seconds: seconds, step: step, recipe: recipe) else { return nil }
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined { _ = try? await manager.requestAuthorization() }
        guard manager.authorizationState == .authorized else {
            return "Allow alarms for roko in Settings to use timers"
        }
        let title = LocalizedStringResource(stringLiteral: recipe)
        let presentation = AlarmPresentation(alert: .init(title: title), countdown: .init(title: title))
        let attributes = AlarmAttributes(presentation: presentation,
                                         metadata: CookTimerMetadata(recipe: recipe, step: step + 1),
                                         tintColor: PageKind.recipe.tint)
        let id = UUID()
        do {
            _ = try await manager.schedule(id: id, configuration: .timer(duration: TimeInterval(seconds), attributes: attributes))
        } catch {
            return "That timer didn't start"
        }
        running.append(Timer(id: id, seconds: seconds, recipe: recipe, step: step, endsAt: .now + TimeInterval(seconds)))
        return nil
    }

    /// Stops it ringing, or calls it off.
    func end(_ timer: Timer) {
        if timer.isRinging { try? AlarmManager.shared.stop(id: timer.id) } else { try? AlarmManager.shared.cancel(id: timer.id) }
        running.removeAll { $0.id == timer.id }
    }
}
