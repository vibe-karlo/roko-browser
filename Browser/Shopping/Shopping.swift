import Foundation
import FoundationModels
import SwiftData

/// A thing to buy, in the aisle it's found in.
@Model
final class ShoppingItem {
    var title: String = ""
    /// An `Aisle`, kept as its name.
    var aisleName: String = Aisle.other.rawValue
    var done: Bool = false
    var doneAt: Date?
    var createdAt: Date = Date.now
    /// Its place in its aisle, dragged there; 0 until moved, then as added.
    var order: Double = 0

    init(title: String, aisle: Aisle) {
        self.title = title
        self.aisleName = aisle.rawValue
    }

    var aisle: Aisle {
        get { Aisle(rawValue: aisleName) ?? .other }
        set { aisleName = newValue.rawValue }
    }

    var key: String { Aisle.key(title) }
}

/// What roko has learned about one thing you buy: how often, how long
/// between, and the aisle you put it in, if you moved it.
@Model
final class ShoppingHabit {
    /// `Aisle.key` of the item: "2x Mlijeko 1L" and "mlijeko" are one habit.
    var key: String = ""
    /// As you last wrote it, for suggesting it back.
    var title: String = ""
    /// Chosen by you (an item moved to another aisle); nil: worked out.
    var chosenAisle: String?
    var count: Int = 0
    var lastAdded: Date?
    /// Days between one time it was added and the next, summed, and how many.
    var gapDays: Double = 0
    var gaps: Int = 0

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }

    /// How often it's usually bought, in days; nil until it's been bought twice.
    var usualGap: Double? { gaps > 0 ? gapDays / Double(gaps) : nil }
}

@MainActor
enum Shopping {
    // MARK: Reading what's typed

    /// The items in what was typed: "mlijeko, jaja i kruh" is three. An "and"
    /// splits only where every part is something to buy on its own ("kruh i
    /// jaja"), not inside one thing ("sok od naranče i jabuke").
    nonisolated static func items(in typed: String) -> [String] {
        let pieces = typed.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.flatMap { piece -> [String] in
            let parts = piece.components(separatedBy: " i ").flatMap { $0.components(separatedBy: " and ") }
                .flatMap { $0.components(separatedBy: " & ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let joining: Set<String> = ["od", "s", "sa", "za", "with", "of", "for", "in", "u"]
            let splits = parts.count > 1 && parts.allSatisfy { part in
                !part.isEmpty && Aisle.of(part) != .other && !Aisle.words(part).contains(where: joining.contains)
            }
            return splits ? parts : [piece]
        }
        .map(capitalized)
    }

    /// "mlijeko" as "Mlijeko"; the rest as written ("iPhone", "NK Osijek" stay).
    nonisolated static func capitalized(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Adding

    /// What was typed, onto the list: each item in its aisle, learned from,
    /// and one already on the list not added twice. Answers what was added
    /// and what was already there.
    @discardableResult
    static func add(_ typed: String, in context: ModelContext) -> (added: [ShoppingItem], already: [String]) {
        let listed = (try? context.fetch(FetchDescriptor<ShoppingItem>(predicate: #Predicate { !$0.done }))) ?? []
        var keys = Set(listed.map(\.key))
        var order = (listed.map(\.order).max() ?? 0) + 1
        var added: [ShoppingItem] = [], already: [String] = []
        for title in items(in: typed) {
            let key = Aisle.key(title)
            guard !key.isEmpty else { continue }
            guard keys.insert(key).inserted else {
                already.append(title)
                continue
            }
            let item = ShoppingItem(title: title, aisle: aisle(for: title, in: context))
            item.order = order
            order += 1
            context.insert(item)
            learn(title, in: context)
            added.append(item)
        }
        try? context.save()
        added.forEach { guessAisle(for: $0, in: context) }
        return (added, already)
    }

    /// What a toast says after adding.
    static func said(_ result: (added: [ShoppingItem], already: [String])) -> String {
        let say = ListLanguage.say
        return switch (result.added.count, result.already.count) {
        case (0, 0): ""
        case (0, 1): say("\(result.already[0]) is already on the list", "\(result.already[0]) je već na popisu")
        case (0, _): say("Already on the list", "Već je na popisu")
        case (1, _): say("\(result.added[0].title) added to Shopping", "\(result.added[0].title) dodano u kupovinu")
        case (let n, _): say("\(n) items added to Shopping", "Dodano u kupovinu: \(n)")
        }
    }

    // MARK: Aisles

    /// Where an item goes: where you put it last time, else its words, else
    /// (in the background) Apple's on-device model.
    static func aisle(for title: String, in context: ModelContext) -> Aisle {
        if let chosen = habit(Aisle.key(title), in: context)?.chosenAisle.flatMap(Aisle.init) { return chosen }
        return Aisle.of(title)
    }

    /// Moved to another aisle: from now on that's where it goes.
    static func move(_ item: ShoppingItem, to aisle: Aisle, in context: ModelContext) {
        item.aisle = aisle
        let habit = habit(item.key, in: context) ?? {
            let new = ShoppingHabit(key: item.key, title: item.title)
            context.insert(new)
            return new
        }()
        habit.chosenAisle = aisle.rawValue
        try? context.save()
    }

    /// Words no rule knows ("kombucha", a brand): Apple's on-device model is
    /// asked, and the item moves when it answers. Nothing waits for it.
    static func guessAisle(for item: ShoppingItem, in context: ModelContext) {
        guard item.aisle == .other, AppleModels.onDeviceAvailable else { return }
        let title = item.title
        Task {
            let session = LanguageModelSession(model: AppleModels.summarizing, instructions: """
                You sort a shopping list into supermarket aisles. Items may be in Croatian or English, \
                with brands. Pick the aisle where a shop keeps the item.
                """)
            guard let answer = try? await session.respond(to: "Item: \(title)", generating: AisleGuess.self).content.aisle.aisle,
                  item.aisle == .other, item.title == title, answer != .other else { return }
            item.aisle = answer
            try? context.save()
        }
    }

    // MARK: Learning

    /// Added to the list: counted, with the time since it was last added.
    static func learn(_ title: String, in context: ModelContext, now: Date = .now) {
        let key = Aisle.key(title)
        guard !key.isEmpty else { return }
        let habit = habit(key, in: context) ?? {
            let new = ShoppingHabit(key: key, title: title)
            context.insert(new)
            return new
        }()
        if let last = habit.lastAdded {
            let days = now.timeIntervalSince(last) / 86_400
            // The same thing added twice in a day is one shop, not two.
            if days >= 1 {
                habit.gapDays += days
                habit.gaps += 1
            } else {
                return
            }
        }
        habit.count += 1
        habit.lastAdded = now
        habit.title = title
    }

    /// What to suggest: things you buy now and then that aren't on the list,
    /// the ones whose usual gap has come round first, then the most often bought.
    static func suggestions(_ habits: [ShoppingHabit], excluding listed: Set<String>, limit: Int = 6,
                            now: Date = .now) -> [ShoppingHabit] {
        habits
            .filter { $0.count >= 2 && !listed.contains($0.key) }
            .map { habit -> (ShoppingHabit, Double) in
                let since = habit.lastAdded.map { now.timeIntervalSince($0) / 86_400 } ?? 0
                // Due: as long ago as it usually is. Otherwise how often it's bought.
                let due = habit.usualGap.map { since / max($0, 1) } ?? 0
                return (habit, (due >= 0.8 ? 100 + min(due, 3) * 10 : 0) + Double(habit.count))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The thing being typed (after the last comma), finished: from what
    /// you've bought before first, then everyday things, then a shop's range.
    /// "mli" is Mlijeko; "jog" is Jogurt, then Dukat jogurt.
    static func completions(for typed: String, in habits: [ShoppingHabit], excluding listed: Set<String>,
                            limit: Int = 4) -> [Completion] {
        let key = Aisle.key(typed.split(separator: ",").last.map(String.init) ?? "")
        guard key.count >= 2 else { return [] }
        let starts = { (other: String) in other.hasPrefix(key) || other.contains(" " + key) }
        var seen = listed.union([key])
        var found: [Completion] = []
        for habit in habits.filter({ starts($0.key) }).sorted(by: { $0.count > $1.count })
        where seen.insert(habit.key).inserted {
            found.append(Completion(title: habit.title, aisle: habit.chosenAisle.flatMap(Aisle.init) ?? Aisle.of(habit.title)))
        }
        for entry in ShoppingCatalogue.shared.matching(key, limit: limit * 3) where found.count < limit && seen.insert(entry.key).inserted {
            found.append(Completion(title: entry.title, aisle: Aisle.of(entry.title)))
        }
        return Array(found.prefix(limit))
    }

    /// What was typed with its last piece finished: "mlijeko, jaja, kr" and Kruh.
    nonisolated static func finishing(_ typed: String, with title: String) -> String {
        (typed.split(separator: ",").dropLast().map(String.init) + [title]).joined(separator: ", ")
    }

    static func habit(_ key: String, in context: ModelContext) -> ShoppingHabit? {
        var descriptor = FetchDescriptor<ShoppingHabit>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Bought more than a month ago: gone from the list (what was learned stays).
    static func tidy(in context: ModelContext) {
        let before = Date.now.addingTimeInterval(-30 * 86_400)
        let old = (try? context.fetch(FetchDescriptor<ShoppingItem>(predicate: #Predicate { $0.done }))) ?? []
        for item in old where (item.doneAt ?? .distantPast) < before { context.delete(item) }
        try? context.save()
    }
}

@Generable
nonisolated struct AisleGuess {
    var aisle: AisleChoice
}

/// `Aisle` as the model answers it (an enum it can only pick from).
@Generable
nonisolated enum AisleChoice {
    case produce, bakery, meat, dairy, frozen, pantry, breakfast, sweets, drinks, household, personal, baby, pets, other

    var aisle: Aisle { Aisle(rawValue: String(describing: self)) ?? .other }
}

/// "shopping milk, eggs", "kupovina mlijeko i kruh": what follows is for the list.
nonisolated enum ShoppingQuery {
    private static let prefixes = ["shopping list ", "shopping ", "groceries ", "kupovina ", "namirnice ", "popis "]

    static func items(in query: String) -> String? {
        let lower = query.lowercased()
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = query.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}

/// A thing to finish the typing with, and where it goes.
nonisolated struct Completion: Identifiable, Sendable {
    let title: String
    let aisle: Aisle
    var id: String { title }
}

/// Everyday things in Croatian and English, then what one shop sells
/// (Resources/Shopping: built from a published price list, sizes and till
/// abbreviations taken out), for finishing what's typed. Read once, off the
/// main thread, as Shopping opens.
nonisolated final class ShoppingCatalogue: Sendable {
    static let shared = ShoppingCatalogue()

    struct Entry: Sendable {
        let title: String
        let key: String
    }

    /// Everyday things first: they're what a list mostly says.
    private let entries: [Entry]

    private init() {
        func read(_ name: String) -> [String] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }
        entries = (read("everyday") + read("products")).map { Entry(title: $0, key: Aisle.key($0)) }
    }

    /// Those whose words start with what's typed: names starting with it
    /// first ("Jogurt"), then ones with it inside ("Dukat jogurt").
    func matching(_ key: String, limit: Int) -> [Entry] {
        var first: [Entry] = [], inside: [Entry] = []
        for entry in entries {
            if entry.key.hasPrefix(key) {
                first.append(entry)
                if first.count >= limit { break }
            } else if inside.count < limit, entry.key.contains(" " + key) {
                inside.append(entry)
            }
        }
        return Array((first + inside).prefix(limit))
    }
}
