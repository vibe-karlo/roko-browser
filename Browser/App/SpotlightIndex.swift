import CoreSpotlight
import SwiftData
import UniformTypeIdentifiers

/// Pins, to-dos and shopping lists in iPhone search. The index stays on the
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
        for todo in (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { !$0.done }))) ?? [] {
            items.append(item(id: "todo|\(todo.createdAt.timeIntervalSinceReferenceDate)", title: todo.title, detail: "To-do", type: .text))
        }
        for thing in (try? context.fetch(FetchDescriptor<ShoppingItem>(predicate: #Predicate { !$0.done }))) ?? [] {
            items.append(item(id: "shopping|\(thing.createdAt.timeIntervalSinceReferenceDate)", title: thing.title, detail: "Shopping", type: .text))
        }
        let fingerprint = items.map { "\($0.uniqueIdentifier)\($0.attributeSet.title ?? "")" }.sorted().joined(separator: "\n")
        guard fingerprint != UserDefaults.standard.string(forKey: key) else { return }
        UserDefaults.standard.set(fingerprint, forKey: key)
        let index = CSSearchableIndex.default()
        index.deleteAllSearchableItems { _ in index.indexSearchableItems(items) }
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

    private static func item(id: String, title: String, detail: String, type: UTType) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: type)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = detail
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: "roko", attributeSet: attributes)
    }
}
