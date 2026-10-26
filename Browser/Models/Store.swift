import Foundation
import SwiftData

/// Where roko keeps its data. Pins, history and to-dos sync through iCloud, in the
/// private database of the person signed in; open tabs and Notify Me stay on
/// this device (tabs are saved after every page load, with their back and
/// forward history, which would only churn the sync; watched pages would
/// otherwise be checked, and notify, on every device).
enum Store {
    static let cloudContainer = "iCloud.com.growthstudio.roko"

    /// Whether this build may sync: signed with the iCloud entitlements (see
    /// project.yml). Without them, CloudKit traps rather than failing politely.
    static var syncs: Bool {
        #if ICLOUD_SYNC
        true
        #else
        false
        #endif
    }

    static func makeContainer() -> ModelContainer {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let synced = ModelConfiguration("Synced", schema: Schema([Pin.self, HistoryEntry.self, Todo.self]),
                                        url: folder.appending(path: "synced.store"),
                                        cloudKitDatabase: syncs ? .private(cloudContainer) : .none)
        // The shopping list stays here for now: shared with family it will go
        // through CloudKit sharing, which needs the paid Developer Program.
        let device = ModelConfiguration("Device", schema: Schema([SavedTab.self, Watch.self, ShoppingItem.self, ShoppingHabit.self]),
                                        url: folder.appending(path: "device.store"), cloudKitDatabase: .none)
        let schema = Schema([Pin.self, HistoryEntry.self, Todo.self, SavedTab.self, Watch.self, ShoppingItem.self, ShoppingHabit.self])
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: synced, device)
        } catch {
            // Never fail to open: without sync, roko is still a browser.
            print("Synced store unavailable, using this device only: \(error)")
            let local = ModelConfiguration("Synced", schema: Schema([Pin.self, HistoryEntry.self, Todo.self]),
                                           url: folder.appending(path: "synced.store"), cloudKitDatabase: .none)
            if let opened = try? ModelContainer(for: schema, configurations: local, device) {
                container = opened
            } else {
                // Still not: a damaged file, a full disk, or the phone not yet unlocked
                // (a background launch). Put the files aside, keeping them, and start
                // afresh; failing that, run with nothing saved rather than not at all.
                print("Store unavailable, starting a new one: \(error)")
                let stamp = Int(Date.now.timeIntervalSince1970)
                for suffix in ["", "-shm", "-wal"] {
                    let file = folder.appending(path: "synced.store" + suffix)
                    try? FileManager.default.moveItem(at: file, to: folder.appending(path: "synced.store.broken-\(stamp)" + suffix))
                }
                if let fresh = try? ModelContainer(for: schema, configurations: local, device) {
                    container = fresh
                } else {
                    let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    container = try! ModelContainer(for: schema, configurations: memory)
                }
            }
        }
        moveFromSingleStore(into: container, folder: folder)
        return container
    }

    /// Before sync, everything lived in one store. Copy it into the two new
    /// ones, once, and keep the old file aside rather than deleting it.
    private static func moveFromSingleStore(into container: ModelContainer, folder: URL) {
        let old = folder.appending(path: "default.store")
        // Not percent-encoded: "Application Support" has a space in it.
        guard FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        do {
            let source = try ModelContainer(for: Pin.self, HistoryEntry.self, SavedTab.self, Watch.self,
                                            configurations: ModelConfiguration(url: old, cloudKitDatabase: .none))
            let from = ModelContext(source)
            let to = container.mainContext
            for pin in try from.fetch(FetchDescriptor<Pin>()) {
                guard let url = URL(string: pin.url) else { continue }
                let copy = Pin(url: url, title: pin.title, order: pin.order)
                copy.createdAt = pin.createdAt
                to.insert(copy)
            }
            for entry in try from.fetch(FetchDescriptor<HistoryEntry>()) {
                guard let url = URL(string: entry.url) else { continue }
                let copy = HistoryEntry(url: url, title: entry.title)
                copy.visitedAt = entry.visitedAt
                copy.visitCount = entry.visitCount
                to.insert(copy)
            }
            for tab in try from.fetch(FetchDescriptor<SavedTab>()) {
                to.insert(SavedTab(tabID: tab.tabID, url: tab.url, title: tab.title, order: tab.order,
                                   lastActive: tab.lastActive, interactionState: tab.interactionState))
            }
            for watch in try from.fetch(FetchDescriptor<Watch>()) {
                guard let url = URL(string: watch.url) else { continue }
                let copy = Watch(url: url, title: watch.title)
                copy.lookFor = watch.lookFor
                copy.everyHours = watch.everyHours
                copy.createdAt = watch.createdAt
                copy.lastChecked = watch.lastChecked
                copy.snapshot = watch.snapshot
                copy.needsRendering = watch.needsRendering
                copy.lastNews = watch.lastNews
                copy.lastNewsAt = watch.lastNewsAt
                to.insert(copy)
            }
            try to.save()
        } catch {
            print("Moving the old store failed: \(error)")
            return
        }
        for suffix in ["", "-shm", "-wal"] {
            let file = folder.appending(path: "default.store" + suffix)
            try? FileManager.default.moveItem(at: file, to: folder.appending(path: "before-sync.store" + suffix))
        }
    }

    /// Two devices can each add the same page before they hear from each
    /// other: fold those into one, keeping the latest visit and every count.
    static func mergeDuplicates(in context: ModelContext) {
        let entries = (try? context.fetch(FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]))) ?? []
        var kept: [String: HistoryEntry] = [:]
        for entry in entries {
            if let first = kept[entry.url] {
                first.visitCount += entry.visitCount
                if first.title.isEmpty { first.title = entry.title }
                context.delete(entry)
            } else {
                kept[entry.url] = entry
            }
        }
        let pins = (try? context.fetch(FetchDescriptor<Pin>(sortBy: [SortDescriptor(\.order)]))) ?? []
        var pinned = Set<String>()
        for pin in pins where !pinned.insert(pin.url).inserted {
            context.delete(pin)
        }
        if context.hasChanges { try? context.save() }
    }
}
