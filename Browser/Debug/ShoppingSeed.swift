#if DEBUG
import Foundation
import SwiftData

/// `-seedShopping`: an empty list and a few months of habits, as the October
/// receipts suggest, to see suggestions without waiting for them.
enum ShoppingSeed {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-seedShopping") }

    @MainActor static func run(in context: ModelContext) {
        try? context.delete(model: ShoppingItem.self)
        try? context.delete(model: ShoppingHabit.self)
        // Title, times bought, days between, days since the last time.
        let habits: [(String, Int, Double, Double)] = [
            ("Mlijeko", 14, 4, 5), ("Banane", 9, 7, 8), ("Kruh", 20, 3, 1), ("Jaja", 8, 7, 2),
            ("Jogurt", 10, 6, 7), ("Pileća prsa", 7, 7, 9), ("Tikvice", 6, 8, 3), ("Borovnice", 6, 7, 6),
            ("Deterdžent", 3, 30, 12), ("Zubna pasta", 3, 25, 26),
        ]
        for (title, count, gap, since) in habits {
            let habit = ShoppingHabit(key: Aisle.key(title), title: title)
            habit.count = count
            habit.gaps = count - 1
            habit.gapDays = gap * Double(count - 1)
            habit.lastAdded = .now.addingTimeInterval(-since * 86_400)
            context.insert(habit)
        }
        try? context.save()
    }
}
#endif
