import ActivityKit
import CoreLocation
import MessageUI
import UIKit
import UserNotifications

/// Paying for street parking by text, in the cities roko knows: where you are
/// gives the zone, your registration goes in the text, and once it's sent the
/// time left runs on the Lock Screen and in the bar. roko never sends the text
/// itself: Messages opens with it written, and you send it.
@Observable
final class Parking {
    static let shared = Parking()

    /// Registrations, as sent: "OS123AB". The first is the one used.
    private(set) var plates: [String] = UserDefaults.standard.stringArray(forKey: "parking.plates") ?? []
    /// The parking being paid for now; nil once it's run out or been ended.
    private(set) var session: Session?
    /// Where you are, in zones, found a moment ago.
    private(set) var match: ParkingMatch?
    private(set) var matchedAt: Date?
    /// Located and not near any paid parking (as opposed to not located yet).
    private(set) var noZoneHere = false
    /// Only a rough fix came (Precise Location off): too rough to pick a zone.
    private(set) var tooRough = false

    struct Session: Codable, Equatable {
        var cityID: String
        var zoneCode: String
        var plate: String
        var startedAt: Date
        var endsAt: Date
        var city: ParkingCity? { ParkingCity.with(id: cityID) }
        var zone: ParkingZone? { city?.zone(zoneCode) }
    }

    @ObservationIgnored private var activity: Activity<ParkingActivityAttributes>?
    /// A short message for the person (set by the browser to its toast).
    @ObservationIgnored var say: ((String) -> Void)?
    private static let reminderID = "roko.parking.reminder"
    /// Lets a simulator, which can't send texts, act as if each one was sent.
    private static let pretendSent = ProcessInfo.processInfo.arguments.contains("-parkingTest")

    private init() {
        if let data = UserDefaults.standard.data(forKey: "parking.session"),
           let saved = try? JSONDecoder().decode(Session.self, from: data), saved.endsAt > .now {
            session = saved
            activity = Activity<ParkingActivityAttributes>.activities.first
        } else {
            // Ran out while roko was closed: its timer goes from the Lock Screen too.
            UserDefaults.standard.removeObject(forKey: "parking.session")
            for stray in Activity<ParkingActivityAttributes>.activities {
                let handle = ActivityHandle(activity: stray)
                Task { await handle.activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    // MARK: Plates

    /// "os 123-ab" → "OS123AB": what the operators expect.
    static func normalized(_ plate: String) -> String {
        plate.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// "OS123AB" → "OS 123 AB", for reading.
    static func display(_ plate: String) -> String {
        var groups: [String] = []
        for character in plate {
            if let last = groups.last?.last, last.isLetter == character.isLetter {
                groups[groups.count - 1].append(character)
            } else {
                groups.append(String(character))
            }
        }
        return groups.joined(separator: " ")
    }

    func addPlate(_ plate: String) {
        let plate = Self.normalized(plate)
        guard plate.count >= 4, !plates.contains(plate) else { return }
        plates.append(plate)
        UserDefaults.standard.set(plates, forKey: "parking.plates")
    }

    func removePlates(at offsets: IndexSet) {
        plates.remove(atOffsets: offsets)
        UserDefaults.standard.set(plates, forKey: "parking.plates")
    }

    func makeDefault(_ plate: String) {
        guard let index = plates.firstIndex(of: plate) else { return }
        plates.insert(plates.remove(at: index), at: 0)
        UserDefaults.standard.set(plates, forKey: "parking.plates")
    }

    // MARK: Where

    /// Finds the zone you're in. A minute old will do: you've parked.
    func locate() async {
        if let matchedAt, Date.now.timeIntervalSince(matchedAt) < 60 { return }
        guard let location = await ParkingLocation.shared.current() else { return }
        // A zone border can run down a street: a fix off by more than this could
        // pick the wrong zone, and a wrong zone is a fine.
        tooRough = location.horizontalAccuracy > 150
        guard !tooRough else {
            match = nil
            noZoneHere = false
            return
        }
        let found = await Task.detached(priority: .userInitiated) { ParkingZones.match(location) }.value
        match = found
        noZoneHere = found == nil && ParkingCity.all.contains { $0.contains(location.coordinate) }
        matchedAt = .now
    }

    // MARK: Paying

    /// The zone's text, written for you to send. Sent, the time starts (or,
    /// for the zone already being paid, carries on an hour longer).
    func pay(_ zone: ParkingZone, in city: ParkingCity) {
        guard let plate = plates.first else { return }
        if let session, session.cityID == city.id, session.zoneCode == zone.code, session.endsAt > .now {
            return extend()
        }
        guard let ends = city.chargingEnds(after: .now) else { return }
        guard Self.pretendSent || MessageComposer.canSend else {
            say?("This iPhone can't send texts")
            return
        }
        Task {
            guard await MessageComposer.send(to: zone.number, body: plate, pretend: Self.pretendSent) else { return }
            let now = Date.now
            let paidUntil = min(now.addingTimeInterval(TimeInterval(zone.ticketMinutes * 60)), ends)
            addPaid(minutes: zone.ticketMinutes, zone: zone, city: city)
            session = Session(cityID: city.id, zoneCode: zone.code, plate: plate, startedAt: now, endsAt: paidUntil)
            saveAndShow()
        }
    }

    /// Another hour, by another text, up to the zone's daily limit.
    func extend() {
        guard let current = session, let zone = current.zone, let city = current.city else { return }
        guard canExtend, let ends = city.chargingEnds(after: .now) else {
            if let limit = zone.maxMinutesPerDay, paidToday(zone: zone, city: city) + zone.ticketMinutes > limit {
                say?("\(zone.name) allows \(limit / 60) hours a day")
            } else {
                say?("Paid until charging ends")
            }
            return
        }
        guard Self.pretendSent || MessageComposer.canSend else {
            say?("This iPhone can't send texts")
            return
        }
        Task {
            guard await MessageComposer.send(to: zone.number, body: current.plate, pretend: Self.pretendSent),
                  var updated = session else { return }
            addPaid(minutes: zone.ticketMinutes, zone: zone, city: city)
            updated.endsAt = min(max(updated.endsAt, .now).addingTimeInterval(TimeInterval(zone.ticketMinutes * 60)), ends)
            session = updated
            saveAndShow()
        }
    }

    /// Whether another text is allowed: within the zone's daily limit, and
    /// while charging lasts past the current end.
    var canExtend: Bool {
        guard let session, let zone = session.zone, let city = session.city,
              let ends = city.chargingEnds(after: .now), session.endsAt < ends else { return false }
        guard let limit = zone.maxMinutesPerDay else { return true }
        return paidToday(zone: zone, city: city) + zone.ticketMinutes <= limit
    }

    /// Stops the timer. What's been paid stays paid.
    func end() {
        session = nil
        UserDefaults.standard.removeObject(forKey: "parking.session")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        guard let activity else { return }
        self.activity = nil
        let handle = ActivityHandle(activity: activity)
        Task { await handle.activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The session while it has time left.
    var active: Session? {
        session.flatMap { $0.endsAt > .now ? $0 : nil }
    }

    /// Run out: let it go (called as the bar opens, not while drawing).
    func clearIfOver() {
        if let session, session.endsAt <= .now { end() }
    }

    // MARK: Keeping it

    private func saveAndShow() {
        guard let session, let zone = session.zone, let city = session.city else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(session), forKey: "parking.session")
        scheduleReminder(session, zone: zone)
        let state = ParkingActivityAttributes.ContentState(endsAt: session.endsAt, canExtend: canExtend)
        let content = ActivityContent(state: state, staleDate: session.endsAt)
        if let activity, activity.activityState == .active {
            let handle = ActivityHandle(activity: activity)
            Task { await handle.activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = ParkingActivityAttributes(zone: zone.name, city: city.name, plate: session.plate)
            activity = try? Activity.request(attributes: attributes, content: content)
        }
    }

    /// Ten minutes before the end (the operator's own text comes later, 5 to 10 before).
    private func scheduleReminder(_ session: Session, zone: ParkingZone) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        let at = session.endsAt.addingTimeInterval(-600)
        guard at > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Parking ends at " + session.endsAt.formatted(date: .omitted, time: .shortened)
        content.body = "\(zone.name) · \(Self.display(session.plate))" + (canExtend ? " · Tap to add an hour" : "")
        content.sound = .default
        content.userInfo = ["url": canExtend ? "roko://parking/extend" : "roko://parking"]
        center.add(UNNotificationRequest(identifier: Self.reminderID, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false)))
        TodoAlerts.askIfNeeded()
    }

    /// Minutes paid in a zone today, across sessions (Osijek's zone 0 allows three hours a day).
    private func paidKey(_ zone: ParkingZone, _ city: ParkingCity) -> String {
        "parking.paid.\(city.id).\(zone.code).\(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private func paidToday(zone: ParkingZone, city: ParkingCity) -> Int {
        UserDefaults.standard.integer(forKey: paidKey(zone, city))
    }

    private func addPaid(minutes: Int, zone: ParkingZone, city: ParkingCity) {
        UserDefaults.standard.set(paidToday(zone: zone, city: city) + minutes, forKey: paidKey(zone, city))
    }
}

/// The Live Activity, handed to the task that updates or ends it. Activity
/// isn't Sendable; roko only ever touches it from the main actor, one call at a time.
nonisolated private struct ActivityHandle: @unchecked Sendable {
    let activity: Activity<ParkingActivityAttributes>
}

/// Messages, with the number and the text written in. True once it's sent.
@MainActor
enum MessageComposer {
    private final class Delegate: NSObject, MFMessageComposeViewControllerDelegate {
        var done: ((Bool) -> Void)?

        nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                                      didFinishWith result: MessageComposeResult) {
            let sent = result == .sent
            MainActor.assumeIsolated {
                controller.dismiss(animated: true)
                done?(sent)
                done = nil
            }
        }
    }

    private static var delegate: Delegate?

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    static func send(to number: String, body: String, pretend: Bool = false) async -> Bool {
        if pretend { return true }
        // One text at a time: a second tap ("Add an hour" twice) waits for nothing.
        guard canSend, delegate == nil, let top = PageDialogs.top, !top.isBeingDismissed else { return false }
        return await withCheckedContinuation { continuation in
            let compose = MFMessageComposeViewController()
            compose.recipients = [number]
            compose.body = body
            let delegate = Delegate()
            delegate.done = { sent in
                Self.delegate = nil
                continuation.resume(returning: sent)
            }
            Self.delegate = delegate
            compose.messageComposeDelegate = delegate
            top.present(compose, animated: true) {
                // Not shown after all: not sent.
                if compose.presentingViewController == nil { delegate.done?(false); delegate.done = nil }
            }
        }
    }
}

/// A precise fix, once, for parking: a town is enough for the weather, but a
/// zone border runs down the middle of a street. With precise location off
/// for roko, iOS is asked for it just this once.
@MainActor
final class ParkingLocation: NSObject, CLLocationManagerDelegate {
    static let shared = ParkingLocation()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private var timeout: Task<Void, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func current() async -> CLLocation? {
        if [.denied, .restricted].contains(manager.authorizationStatus) { return nil }
        if let last = manager.location, Date.now.timeIntervalSince(last.timestamp) < 30, last.horizontalAccuracy <= 50 { return last }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                locate()
            }
        }
    }

    private func locate() {
        if manager.accuracyAuthorization == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Parking")
        }
        manager.requestLocation()
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self.finish(nil)
        }
    }

    private func finish(_ location: CLLocation?) {
        timeout?.cancel()
        timeout = nil
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: if !waiting.isEmpty { locate() }
            case .denied, .restricted: finish(nil)
            default: break
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
