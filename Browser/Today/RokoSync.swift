import Foundation
import SwiftData
import UIKit

/// roko's own sync, through roko's server (Server/share, /api/sync): to-dos,
/// the shopping lists and Read Later kept the same here and on the Mac (the
/// Raycast extension), and links sent from the Mac opened here as tabs.
///
/// How things looked at the last sync is kept on this device (`snapshot`): a
/// to-do that no longer looks like that changed here, and goes up with the time
/// it changed; one that's gone was deleted here. Then whatever changed on the
/// server since the last round comes down and is put in place. When both sides
/// changed one thing, the server keeps the later change.
///
/// While roko is open it asks every few seconds. Closed, it catches up when
/// opened; push notifications (with the paid Developer Program) can wake it later.
@MainActor
enum RokoSync {
    /// The server: the same as shared pages'. None in this build, and there's no sync.
    static var server: URL? { AnswerSharing.server }
    static var isOn: Bool { Keychain.syncKey != nil && server != nil }

    private static let seqKey = "sync.seq"
    private static let snapshotKey = "sync.snapshot"
    private static let openedKey = "sync.openedLinks"
    private static let pendingLinksKey = "sync.pendingLinks"
    /// While open: how often to ask for what changed on the Mac.
    private static let pollInterval: Duration = .seconds(4)

    private static var container: ModelContainer?
    private static var running = false
    private static var again = false
    private static var pending: Task<Void, Never>?
    private static var poller: Task<Void, Never>?
    /// Saves roko makes while putting the server's changes in place don't start a round of their own.
    private static var applying = false

    /// Opens a link sent from the Mac, as a new tab. Set once the browser is up;
    /// links that arrive before wait for it.
    static var openLink: ((URL) -> Void)? {
        didSet { openPendingLinks() }
    }

    /// When it last spoke to the server, and what went wrong if it couldn't, for Settings.
    private(set) static var lastSynced: Date?
    private(set) static var problem: String?

    // MARK: Turning it on and off

    /// A new space on the server; this iPhone keeps its key. What's here goes up.
    static func turnOn() async throws {
        guard let server else { throw SyncError("Sync isn't set up in this build.") }
        var request = URLRequest(url: server.appending(path: "api/sync/space"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.quick.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201,
              let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["key"] as? String else {
            throw SyncError(message(in: data) ?? "roko's server didn't answer. Try again in a moment.")
        }
        join(key)
    }

    /// A key from another device: this one joins its space, and what's here
    /// is added to what's there.
    static func join(_ key: String) {
        Keychain.syncKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        resetState()
        problem = nil
        schedule(after: .zero)
        startPolling()
    }

    /// Off on this iPhone: nothing is deleted, here or on the server.
    static func turnOff() {
        Keychain.syncKey = nil
        resetState()
        poller?.cancel()
        poller = nil
    }

    /// The space and everything in it gone from the server; it stays on this iPhone.
    static func deleteFromServer() async throws {
        guard let server, let key = Keychain.syncKey else { return }
        var request = URLRequest(url: server.appending(path: "api/sync/space"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.quick.data(for: request)
        guard [204, 404].contains((response as? HTTPURLResponse)?.statusCode) else {
            throw SyncError("roko's server didn't answer. Try again in a moment.")
        }
        turnOff()
    }

    private static func resetState() {
        UserDefaults.standard.removeObject(forKey: seqKey)
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        lastSynced = nil
    }

    // MARK: When

    static func start(_ container: ModelContainer) {
        self.container = container
        // Changed here: a save that touched a to-do or a thing to buy.
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            let touched = keys.contains { key in
                (note.userInfo?[key.rawValue] as? [PersistentIdentifier])?.contains {
                    $0.entityName == "Todo" || $0.entityName == "ShoppingItem"
                } ?? false
            }
            guard touched else { return }
            MainActor.assumeIsolated {
                guard !applying else { return }
                schedule(after: .milliseconds(600))
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                schedule(after: .zero)
                startPolling()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                poller?.cancel()
                poller = nil
            }
        }
        schedule(after: .seconds(1))
        startPolling()
    }

    /// Read Later changed here (it keeps its own file, not the model store).
    static func readLaterChanged() {
        guard !applying else { return }
        schedule(after: .milliseconds(600))
    }

    /// A round soon; several changes in a row make one.
    static func schedule(after delay: Duration) {
        guard isOn else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    private static func startPolling() {
        guard isOn, poller == nil else { return }
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, isOn else { break }
                if UIApplication.shared.applicationState == .active { await sync() }
            }
        }
    }

    // MARK: The round

    private static func sync() async {
        guard let server, let key = Keychain.syncKey, let context = container?.mainContext else { return }
        if running {
            again = true
            return
        }
        running = true
        defer {
            running = false
            if again {
                again = false
                schedule(after: .milliseconds(300))
            }
        }
        do {
            var snapshot = loadSnapshot()

            // Up: what changed here since the last round.
            let local = localRecords(in: context)
            let now = Int64((Date.now.timeIntervalSince1970 * 1000).rounded())
            var outgoing: [[String: Any]] = []
            for (id, record) in local where snapshot[id] != record {
                outgoing.append(["kind": id.kind, "id": id.id, "updated": now, "data": record.object])
            }
            // Everything of a kind gone at once is far likelier a store that didn't
            // open than deletions: nothing of that kind is deleted then.
            // (Deleting the last one or three by hand still goes through.)
            let present = Set(local.keys.map(\.kind))
            let protected = Set(["todo", "shopping", "later"].filter { kind in
                !present.contains(kind) && snapshot.keys.filter { $0.kind == kind }.count > 3
            })
            let gone = snapshot.keys.filter { $0.kind != "link" && local[$0] == nil && !protected.contains($0.kind) }
            for id in gone {
                outgoing.append(["kind": id.kind, "id": id.id, "updated": now, "deleted": true])
            }
            // Links already opened here, cleared on the server for every device.
            for id in clearedLinks() {
                outgoing.append(["kind": "link", "id": id, "updated": now, "deleted": true])
            }
            // Read Later goes in requests of its own: a server from before it
            // turns the kind down, and that mustn't hold up the to-dos.
            let later = outgoing.filter { $0["kind"] as? String == "later" }
            let rest = outgoing.filter { $0["kind"] as? String != "later" }
            for batch in stride(from: 0, to: rest.count, by: 400).map({ Array(rest[$0..<min($0 + 400, rest.count)]) }) {
                _ = try await call(server, key, method: "POST", body: ["changes": batch])
            }
            var laterSent = true
            do {
                for batch in stride(from: 0, to: later.count, by: 400).map({ Array(later[$0..<min($0 + 400, later.count)]) }) {
                    _ = try await call(server, key, method: "POST", body: ["changes": batch])
                }
            } catch {
                laterSent = false
            }
            for (id, record) in local where snapshot[id] != record && (laterSent || id.kind != "later") { snapshot[id] = record }
            for id in gone where laterSent || id.kind != "later" { snapshot[id] = nil }
            if !outgoing.isEmpty { forgetClearedLinks() }

            // Down: what changed on the server since the last round, this
            // iPhone's own changes included (they're already in place).
            var seq = UserDefaults.standard.integer(forKey: seqKey)
            var more = true
            while more {
                let page = try await call(server, key, method: "GET", query: "since=\(seq)")
                let changes = page["changes"] as? [[String: Any]] ?? []
                apply(changes, to: &snapshot, in: context)
                seq = page["seq"] as? Int ?? seq
                more = page["more"] as? Bool ?? false
            }
            UserDefaults.standard.set(seq, forKey: seqKey)
            saveSnapshot(snapshot)
            lastSynced = .now
            problem = nil
        } catch let error as SyncError {
            problem = error.message
        } catch {
            // Offline or the server away: the next round tries again.
            problem = "Couldn't reach roko's server."
        }
    }

    // MARK: Here and there

    /// A synced thing: its kind and its id.
    struct RecordID: Hashable, Codable {
        let kind: String
        let id: String
        var key: String { "\(kind)/\(id)" }
        init(kind: String, id: String) { self.kind = kind; self.id = id }
        init?(key: String) {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            self.init(kind: String(parts[0]), id: String(parts[1]))
        }
    }

    /// What's here now, as it's sent. Things without a sync id get one.
    private static func localRecords(in context: ModelContext) -> [RecordID: Record] {
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let items = (try? context.fetch(FetchDescriptor<ShoppingItem>())) ?? []
        var named = false
        for todo in todos where todo.syncID.isEmpty { todo.syncID = UUID().uuidString; named = true }
        for item in items where item.syncID.isEmpty { item.syncID = UUID().uuidString; named = true }
        if named {
            applying = true
            try? context.save()
            applying = false
        }
        var records: [RecordID: Record] = [:]
        for todo in todos { records[RecordID(kind: "todo", id: todo.syncID)] = .todo(TodoRecord(todo)) }
        for item in items { records[RecordID(kind: "shopping", id: item.syncID)] = .shopping(ShoppingRecord(item)) }
        for page in ReadLater.shared.pages { records[RecordID(kind: "later", id: page.id.uuidString)] = .later(LaterRecord(page)) }
        return records
    }

    /// The server's changes, put in place here.
    private static func apply(_ changes: [[String: Any]], to snapshot: inout [RecordID: Record], in context: ModelContext) {
        guard !changes.isEmpty else { return }
        var todos: [String: Todo]?
        var items: [String: ShoppingItem]?
        applying = true
        defer {
            try? context.save()
            applying = false
        }
        for change in changes {
            guard let kind = change["kind"] as? String, let id = change["id"] as? String else { continue }
            let recordID = RecordID(kind: kind, id: id)
            let deleted = change["deleted"] as? Bool ?? false
            let data = change["data"] as? [String: Any]
            switch kind {
            case "todo":
                if todos == nil { todos = byID((try? context.fetch(FetchDescriptor<Todo>())) ?? [], \.syncID) }
                if deleted || data == nil {
                    if let todo = todos?[id] { context.delete(todo); todos?[id] = nil }
                    snapshot[recordID] = nil
                } else if let record = TodoRecord(data!), snapshot[recordID] != .todo(record) {
                    let todo = todos?[id] ?? {
                        let made = Todo(title: record.title, when: .someday)
                        made.syncID = id
                        context.insert(made)
                        todos?[id] = made
                        return made
                    }()
                    record.apply(to: todo)
                    // What the server has: if it was missing something (written on
                    // the Mac), the next round sends roko's fuller version back.
                    snapshot[recordID] = .todo(record)
                }
            case "shopping":
                if items == nil { items = byID((try? context.fetch(FetchDescriptor<ShoppingItem>())) ?? [], \.syncID) }
                if deleted || data == nil {
                    if let item = items?[id] { context.delete(item); items?[id] = nil }
                    snapshot[recordID] = nil
                } else if let record = ShoppingRecord(data!), snapshot[recordID] != .shopping(record) {
                    let isNew = items?[id] == nil
                    let item = items?[id] ?? {
                        let made = ShoppingItem(title: record.title, aisle: .other)
                        made.syncID = id
                        context.insert(made)
                        items?[id] = made
                        return made
                    }()
                    record.apply(to: item, in: context)
                    // Added on the Mac: learned like anything typed here.
                    if isNew { Shopping.learn(record.title, in: context) }
                    snapshot[recordID] = .shopping(record)
                }
            case "later":
                guard let uuid = UUID(uuidString: id) else { continue }
                if deleted || data == nil {
                    ReadLater.shared.removeSynced(uuid)
                    snapshot[recordID] = nil
                } else if let record = LaterRecord(data!), snapshot[recordID] != .later(record) {
                    ReadLater.shared.applySynced(record, id: uuid)
                    snapshot[recordID] = .later(record)
                }
            case "link":
                guard !deleted, let data, let string = data["url"] as? String, let url = URL(string: string),
                      url.scheme == "https" || url.scheme == "http" else { continue }
                queueLink(id: id, url: url)
            default:
                continue
            }
        }
    }

    private static func byID<T>(_ things: [T], _ id: KeyPath<T, String>) -> [String: T] {
        var map: [String: T] = [:]
        for thing in things where !thing[keyPath: id].isEmpty { map[thing[keyPath: id]] = thing }
        return map
    }

    // MARK: Links from the Mac

    /// Links waiting to be opened, by id, and those opened and still to be cleared.
    private static func queueLink(id: String, url: URL) {
        var opened = UserDefaults.standard.stringArray(forKey: openedKey) ?? []
        guard !opened.contains(id) else { return }
        var waiting = UserDefaults.standard.dictionary(forKey: pendingLinksKey) as? [String: String] ?? [:]
        waiting[id] = url.absoluteString
        UserDefaults.standard.set(waiting, forKey: pendingLinksKey)
        opened.append(id)
        UserDefaults.standard.set(Array(opened.suffix(200)), forKey: openedKey)
        openPendingLinks()
    }

    private static func openPendingLinks() {
        guard let openLink else { return }
        let waiting = UserDefaults.standard.dictionary(forKey: pendingLinksKey) as? [String: String] ?? [:]
        guard !waiting.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: pendingLinksKey)
        for (id, string) in waiting.sorted(by: { $0.key < $1.key }) {
            if let url = URL(string: string) { openLink(url) }
            var cleared = UserDefaults.standard.stringArray(forKey: clearedKey) ?? []
            cleared.append(id)
            UserDefaults.standard.set(cleared, forKey: clearedKey)
        }
        schedule(after: .milliseconds(300))
    }

    private static let clearedKey = "sync.clearedLinks"
    private static func clearedLinks() -> [String] { UserDefaults.standard.stringArray(forKey: clearedKey) ?? [] }
    private static func forgetClearedLinks() { UserDefaults.standard.removeObject(forKey: clearedKey) }

    // MARK: The server

    private static func call(_ server: URL, _ key: String, method: String, query: String? = nil,
                             body: [String: Any]? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: server.appending(path: "api/sync"), resolvingAgainstBaseURL: false)!
        components.query = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.quick.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SyncError(message(in: data) ?? (status == 401
                ? "This key isn't known to roko's server any more. Turn sync off and on again."
                : "roko's server didn't answer. Trying again shortly."))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func message(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    struct SyncError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: The snapshot

    private static var snapshotFile: URL { URL.applicationSupportDirectory.appending(path: "sync-snapshot.json") }

    private static func loadSnapshot() -> [RecordID: Record] {
        guard let data = try? Data(contentsOf: snapshotFile),
              let stored = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        var snapshot: [RecordID: Record] = [:]
        for (key, record) in stored { if let id = RecordID(key: key) { snapshot[id] = record } }
        return snapshot
    }

    private static func saveSnapshot(_ snapshot: [RecordID: Record]) {
        var stored: [String: Record] = [:]
        for (id, record) in snapshot { stored[id.key] = record }
        try? JSONEncoder().encode(stored).write(to: snapshotFile, options: .atomic)
    }
}

// MARK: What's sent

/// A synced thing as it travels: a to-do, a thing to buy or a page to read later.
enum Record: Codable, Equatable {
    case todo(TodoRecord)
    case shopping(ShoppingRecord)
    case later(LaterRecord)

    var object: [String: Any] {
        let data: Data? = switch self {
        case .todo(let record): try? JSONEncoder().encode(record)
        case .shopping(let record): try? JSONEncoder().encode(record)
        case .later(let record): try? JSONEncoder().encode(record)
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

private func milliseconds(_ date: Date?) -> Int64? {
    date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
}

private func date(_ milliseconds: Int64?) -> Date? {
    milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
}

/// A day as "2026-10-28", the same wherever the Mac and the iPhone are.
private let dayFormat: DateFormatter = {
    let format = DateFormatter()
    format.calendar = Calendar(identifier: .gregorian)
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd"
    return format
}()

private let clockFormat: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "HH:mm"
    return format
}()

/// A to-do: its day as a date ("2026-10-28"), "week" when it's for the week
/// ending that day, a time as "15:30"; no day is Someday.
struct TodoRecord: Codable, Equatable {
    var title: String
    var day: String?
    var week: Bool?
    var time: String?
    var done: Bool?
    var doneAt: Int64?
    var order: Double?
    var created: Int64?

    init(_ todo: Todo) {
        title = todo.title
        day = todo.day.map(dayFormat.string)
        week = todo.wholeWeek
        time = todo.time.map(clockFormat.string)
        done = todo.done
        doneAt = milliseconds(todo.doneAt)
        order = todo.order
        created = milliseconds(todo.createdAt)
    }

    init?(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let record = try? JSONDecoder().decode(TodoRecord.self, from: data),
              !record.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self = record
    }

    @MainActor
    func apply(to todo: Todo) {
        todo.title = title
        let calendar = Calendar.current
        todo.day = day.flatMap(dayFormat.date).map(calendar.startOfDay)
        todo.wholeWeek = (week ?? false) && todo.day != nil
        if let time, let clock = clockFormat.date(from: time), let day = todo.day, !todo.wholeWeek {
            let parts = calendar.dateComponents([.hour, .minute], from: clock)
            todo.time = calendar.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day)
        } else {
            todo.time = nil
        }
        let isDone = done ?? false
        if isDone != todo.done || todo.doneAt == nil && isDone {
            todo.done = isDone
            todo.doneAt = isDone ? (date(doneAt) ?? .now) : nil
        }
        if let order { todo.order = order }
        if let created = date(created) { todo.createdAt = created }
    }
}

/// A thing to buy: its aisle, the shop whose list it's on ("grocery",
/// "drugstore", "pharmacy"), and `pinned` when it was put there by hand.
/// Written on the Mac it may have no aisle: roko works one out, as for typing.
struct ShoppingRecord: Codable, Equatable {
    var title: String
    var aisle: String?
    var shop: String?
    var pinned: String?
    var done: Bool?
    var doneAt: Int64?
    var order: Double?
    var created: Int64?

    init(_ item: ShoppingItem) {
        title = item.title
        aisle = item.aisleName
        shop = item.shop.rawValue
        pinned = item.shopName
        done = item.done
        doneAt = milliseconds(item.doneAt)
        order = item.order
        created = milliseconds(item.createdAt)
    }

    init?(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let record = try? JSONDecoder().decode(ShoppingRecord.self, from: data),
              !record.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self = record
    }

    @MainActor
    func apply(to item: ShoppingItem, in context: ModelContext) {
        item.title = title
        item.aisle = aisle.flatMap(Aisle.init) ?? Shopping.aisle(for: title, in: context)
        item.shopName = pinned.flatMap(Shop.init)?.rawValue ?? ""
        let isDone = done ?? false
        if isDone != item.done || item.doneAt == nil && isDone {
            item.done = isDone
            item.doneAt = isDone ? (date(doneAt) ?? .now) : nil
        }
        if let order { item.order = order }
        if let created = date(created) { item.createdAt = created }
    }
}

/// A page saved to Read Later, without its text: the server keeps a few
/// kilobytes a thing. Saved on the Mac, its text is read here when it arrives.
struct LaterRecord: Codable, Equatable {
    var url: String
    var title: String
    var site: String?
    /// The page's share picture, for the Mac's list.
    var image: String?
    var saved: Int64?
    var read: Int64?

    init(_ page: ReadLaterPage) {
        url = page.url.absoluteString
        title = page.title
        site = page.site
        image = page.imageURL?.absoluteString
        saved = milliseconds(page.savedAt)
        read = milliseconds(page.readAt)
    }

    init?(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let record = try? JSONDecoder().decode(LaterRecord.self, from: data),
              let url = URL(string: record.url), url.scheme == "https" || url.scheme == "http" else { return nil }
        self = record
    }

    var savedAt: Date? { date(saved) }
    var readAt: Date? { date(read) }
}
