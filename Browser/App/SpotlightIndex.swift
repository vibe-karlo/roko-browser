@preconcurrency import CoreSpotlight
import SwiftData
import UniformTypeIdentifiers

/// iPhone search: your pinned sites, and a way straight into the to-do and
/// shopping lists. What's on those lists stays out of it. The index stays on the
/// iPhone. Refreshed as roko is left, and only when something in it changed.
@MainActor
enum SpotlightIndex {
    private static let key = "spotlight.fingerprint"

    static func update(_ container: ModelContainer) {
        let context = container.mainContext
        var items: [CSSearchableItem] = []
        for pin in (try? context.fetch(FetchDescriptor<Pin>())) ?? [] {
            items.append(item(id: "pin|\(pin.url)", title: pin.title.isEmpty ? pin.host : pin.title, detail: pin.host, type: .url))
        }
        items.append(item(id: "todo", title: ListLanguage.say("To-do list", "Popis zadataka"), detail: "roko", type: .text,
                          keywords: ["to-do", "todo", "tasks", "zadaci", "popis"]))
        items.append(item(id: "shopping", title: ListLanguage.say("Shopping list", "Popis za kupovinu"), detail: "roko", type: .text,
                          keywords: ["shopping", "groceries", "kupovina", "namirnice", "popis"]))
        let fingerprint = items.map { "\($0.uniqueIdentifier)\($0.attributeSet.title ?? "")" }.sorted().joined(separator: "\n")
        guard fingerprint != UserDefaults.standard.string(forKey: key) else { return }
        UserDefaults.standard.set(fingerprint, forKey: key)
        let index = CSSearchableIndex.default()
        let indexing = items
        index.deleteAllSearchableItems { _ in index.indexSearchableItems(indexing) }
    }

    /// A result was tapped: its page, or the list it's on.
    static func open(_ activity: NSUserActivity, in browser: BrowserModel) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        switch parts.first {
        case "pin":
            if parts.count > 1, let url = URL(string: parts[1]) {
                browser.panel = .none
                browser.open(url, inNewTab: true)
            }
        case "todo": browser.panel = .todos
        case "shopping": browser.panel = .shopping
        default: break
        }
    }

    private static func item(id: String, title: String, detail: String, type: UTType, keywords: [String] = []) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: type)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = detail
        attributes.keywords = keywords
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: "roko", attributeSet: attributes)
    }
}
