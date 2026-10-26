import Foundation

/// Settings and per-site choices, kept the same on every device through
/// iCloud's key-value store: the search engine, what's blocked, and what you
/// chose for a site (blocking off, cookies accepted, zoom). Things that
/// belong to one device stay there: the app icon, the Claude key (in the
/// Keychain), caches.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    /// True while writing what came from iCloud, so it isn't sent straight back.
    private var applying = false
    private var pendingPush: Task<Void, Never>?
    /// Keys this device has sent, so one removed here is removed everywhere.
    private static let sentKey = "sync.sentKeys"

    private static let exact: Set<String> = [
        "searchEngine", "suggestions", "archivePolicy", ClaudeClient.enabledKey, "consent.acceptedHosts", AnswerLanguage.key, AnswerLanguage.keptKey,
        Preferences.voiceLanguagesKey, Preferences.pullToSummarizeKey,
    ]
    private static let prefixes = ["block.", "zoom."]

    static func syncs(_ key: String) -> Bool {
        exact.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    func start() {
        guard Store.syncs else { return }
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: cloud, queue: .main) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pull(keys) }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePush() }
        }
        cloud.synchronize()
        // What other devices already chose comes first; then this device adds
        // anything iCloud doesn't have yet.
        pull(nil)
        push()
    }

    /// Writes iCloud's values here. nil: every synced key iCloud holds.
    private func pull(_ keys: [String]?) {
        let keys = (keys ?? Array(cloud.dictionaryRepresentation.keys)).filter(Self.syncs)
        guard !keys.isEmpty else { return }
        applying = true
        for key in keys {
            if let value = cloud.object(forKey: key) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        var sent = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        sent.formUnion(keys.filter { cloud.object(forKey: $0) != nil })
        defaults.set(Array(sent), forKey: Self.sentKey)
        applying = false
        // Blocking choices apply from the next page, as when changed here.
        if keys.contains(where: { $0.hasPrefix("block.") || $0 == "consent.acceptedHosts" }) {
            ContentBlocker.shared.settingsChanged()
        }
    }

    private func schedulePush() {
        guard !applying else { return }
        pendingPush?.cancel()
        pendingPush = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            push()
        }
    }

    /// Sends what changed here: new or changed values, and removals of keys
    /// this device sent before (a site's zoom set back to 100%, say).
    private func push() {
        let local = defaults.dictionaryRepresentation().filter { Self.syncs($0.key) }
        var sent = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        var changed = false
        for (key, value) in local where !((cloud.object(forKey: key) as? NSObject)?.isEqual(value) ?? false) {
            cloud.set(value, forKey: key)
            changed = true
        }
        for key in sent where local[key] == nil && cloud.object(forKey: key) != nil {
            cloud.removeObject(forKey: key)
            changed = true
        }
        sent = Set(local.keys)
        applying = true
        defaults.set(Array(sent), forKey: Self.sentKey)
        applying = false
        if changed { cloud.synchronize() }
    }
}
