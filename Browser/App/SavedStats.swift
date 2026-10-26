import Foundation

/// What roko did for you, counted as it happens, with the time it saved
/// estimated from what was actually done: the clicks a cookie pop-up took,
/// the words a summary spared you, the pages Browse for Me read for you.
/// Kept on this device; nothing about the pages themselves is stored.
enum SavedStats {
    private static let defaults = UserDefaults.standard
    static let changed = Notification.Name("roko.savedStatsChanged")

    /// Reading speed for skimming an article, words a minute.
    private static let readingSpeed = 230.0
    /// A click on a cookie pop-up, finding the button included.
    private static let secondsPerClick = 3.0

    struct Totals {
        var cookieBars = 0, cookieClicks = 0, cookieSeconds = 0.0
        var summaries = 0, summarySeconds = 0.0
        var answers = 0, answerSeconds = 0.0
        var instant = 0, instantSeconds = 0.0
        var since: Date?

        var seconds: Double { cookieSeconds + summarySeconds + answerSeconds + instantSeconds }
    }

    static var totals: Totals {
        Totals(cookieBars: defaults.integer(forKey: "saved.cookieBars"),
               cookieClicks: defaults.integer(forKey: "saved.cookieClicks"),
               cookieSeconds: defaults.double(forKey: "saved.cookieSeconds"),
               summaries: defaults.integer(forKey: "saved.summaries"),
               summarySeconds: defaults.double(forKey: "saved.summarySeconds"),
               answers: defaults.integer(forKey: "saved.answers"),
               answerSeconds: defaults.double(forKey: "saved.answerSeconds"),
               instant: defaults.integer(forKey: "saved.instant"),
               instantSeconds: defaults.double(forKey: "saved.instantSeconds"),
               since: defaults.object(forKey: "saved.since") as? Date)
    }

    /// A cookie pop-up answered without you: at least the one click it
    /// would have taken, more where it took more (settings, then reject).
    static func cookieBar(clicks: Int) {
        let clicks = max(1, clicks)
        add(1, to: "saved.cookieBars")
        add(clicks, to: "saved.cookieClicks")
        add(Double(clicks) * secondsPerClick, to: "saved.cookieSeconds")
    }

    /// A page read as a summary: the reading it spared, at skimming speed,
    /// at most half an hour for one page.
    static func summary(pageWords: Int, summaryWords: Int) {
        let seconds = min(1800, max(0, Double(pageWords - summaryWords) / readingSpeed * 60))
        guard seconds > 0 else { return }
        add(1, to: "saved.summaries")
        add(seconds, to: "saved.summarySeconds")
    }

    /// An answer from Browse for Me: a search and a look at each page it read,
    /// less the time to read the answer; half a minute at the least.
    static func answer(pagesRead: Int, answerWords: Int) {
        let seconds = max(30, 20 + 60 * Double(min(pagesRead, 8)) - Double(answerWords) / readingSpeed * 60)
        add(1, to: "saved.answers")
        add(seconds, to: "saved.answerSeconds")
    }

    /// An answer read in the address bar (a sum, a rate, a time zone, the
    /// weather, what's next in the calendar) instead of looked up elsewhere.
    static func instantAnswer(seconds: Double) {
        add(1, to: "saved.instant")
        add(seconds, to: "saved.instantSeconds")
    }

    static func reset() {
        for key in ["saved.cookieBars", "saved.cookieClicks", "saved.cookieSeconds", "saved.summaries",
                    "saved.summarySeconds", "saved.answers", "saved.answerSeconds", "saved.instant",
                    "saved.instantSeconds"] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(Date.now, forKey: "saved.since")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Counted in one pass over the bytes, nothing allocated: a long article
    /// is a few hundred thousand of them.
    nonisolated static func words(in text: String) -> Int {
        var count = 0, inWord = false
        for byte in text.utf8 {
            let space = byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
            if !space, !inWord { count += 1 }
            inWord = !space
        }
        return count
    }

    private static func add(_ amount: Int, to key: String) {
        noteStart()
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func add(_ amount: Double, to key: String) {
        noteStart()
        defaults.set(defaults.double(forKey: key) + amount, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func noteStart() {
        if defaults.object(forKey: "saved.since") == nil { defaults.set(Date.now, forKey: "saved.since") }
    }

    /// "3 h 20 min", "12 min", "40 s".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        if minutes >= 1 { return "\(minutes) min" }
        return "\(Int(seconds)) s"
    }
}
