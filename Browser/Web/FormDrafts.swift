import Foundation

/// What you've typed into a page's form and not sent yet, by tab, so it comes
/// back if the page crashes or roko is closed. Never for a private tab, never
/// passwords or card numbers (page-watch.js leaves them out). Kept in a file
/// only this iPhone can read while it's unlocked, for a week at most.
@MainActor
enum FormDrafts {
    struct Draft: Codable {
        var url: URL
        var fields: [String: String]
        var savedAt: Date
    }

    private static let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("FormDrafts.json")
    }()

    private static var drafts: [UUID: Draft] = {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([UUID: Draft].self, from: data) else { return [:] }
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
        return saved.filter { $0.value.savedAt > cutoff }
    }()

    static func draft(for tab: UUID) -> Draft? {
        drafts[tab]
    }

    static func set(_ draft: Draft?, for tab: UUID) {
        guard drafts[tab]?.fields != draft?.fields || drafts[tab]?.url != draft?.url else { return }
        drafts[tab] = draft
        write()
    }

    /// Tabs that are gone take their drafts with them.
    static func keep(only tabs: Set<UUID>) {
        let before = drafts.count
        drafts = drafts.filter { tabs.contains($0.key) }
        if drafts.count != before { write() }
    }

    private static var pendingWrite: Task<Void, Never>?

    private static func write() {
        pendingWrite?.cancel()
        let snapshot = drafts
        pendingWrite = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }
}
