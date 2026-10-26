import BackgroundTasks
import FoundationModels
import SwiftData
import UserNotifications
import WebKit

/// How often Notify Me checks a page. iOS picks the exact moment.
enum WatchFrequency: Int, CaseIterable, Identifiable {
    case hourly = 1, daily = 24, weekly = 168

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

/// Notify Me: checks the watched pages that are due, and notifies you when one
/// shows what you asked for (or, if you didn't say, anything new).
enum Watcher {
    private static var isRunning = false

    /// Reads a new watch's page as it is now, for later checks to compare with.
    static func begin(_ watch: Watch, in context: ModelContext) async {
        guard let url = URL(string: watch.url) else { return }
        var lines = await PageLines.fetch(url)
        // Next to nothing without its scripts: read it rendered instead, from now on.
        if lines.map(PageLines.isThin) ?? true, let rendered = await RenderedPage.lines(of: url),
           lines == nil || !PageLines.isThin(rendered) {
            lines = rendered
            watch.needsRendering = true
        }
        watch.snapshot = (lines ?? []).joined(separator: "\n")
        watch.lastChecked = .now
        watch.readingVersion = PageLines.version
        try? context.save()
    }

    /// Checks every watch that's due. In the background only the pages that
    /// can be read without running their scripts; with roko open, all of them.
    static func runDue(in container: ModelContainer, inBackground: Bool, force: Bool = false) async {
        // One already going (iOS woke roko as it opened): it books the next
        // wake-up when it's done, but so does this, so the chain never breaks.
        guard !isRunning else {
            WatchScheduler.schedule(in: container.mainContext)
            return
        }
        isRunning = true
        defer { isRunning = false }
        let context = container.mainContext
        let watches = (try? context.fetch(FetchDescriptor<Watch>())) ?? []
        let due = watches.filter { watch in
            (force || watch.nextCheck <= .now.addingTimeInterval(5 * 60)) && !(inBackground && watch.needsRendering)
        }
        if LaunchClock.isEnabled { print("WATCH \(due.count) of \(watches.count) due\(inBackground ? " in the background" : "")") }
        if !due.isEmpty {
            // All at once, off the main thread: the background allows only seconds.
            let read = await withTaskGroup(of: (Int, [String]?).self) { group in
                // Plainly first even where scripts were needed: roko may read it now.
                for (index, watch) in due.enumerated() {
                    guard let url = URL(string: watch.url) else { continue }
                    group.addTask { (index, await PageLines.fetch(url)) }
                }
                var read: [Int: [String]] = [:]
                for await (index, lines) in group { read[index] = lines }
                return read
            }
            for (index, watch) in due.enumerated() {
                guard !Task.isCancelled else { break }
                var lines = read[index]
                if watch.needsRendering, let url = URL(string: watch.url) {
                    if let plain = lines, !PageLines.isThin(plain) {
                        // Readable plainly now: back to background checks, its
                        // reading taken afresh (rendered and plain text differ).
                        watch.needsRendering = false
                        watch.snapshot = plain.joined(separator: "\n")
                        watch.readingVersion = PageLines.version
                        watch.lastChecked = .now
                        try? context.save()
                        continue
                    } else {
                        lines = await RenderedPage.lines(of: url)
                    }
                }
                // Offline, or the page didn't load: it's still due, so next time.
                guard let lines else { continue }
                await compare(watch, with: lines)
                // Each as it's done: a page read in a web view takes up to 20
                // seconds, and roko left before then kept nothing, so the next
                // check compared with the old reading and told the same news again.
                try? context.save()
            }
        }
        WatchScheduler.schedule(watches)
    }

    private static func compare(_ watch: Watch, with lines: [String]) async {
        let old = watch.snapshot.split(separator: "\n").map(String.init)
        watch.lastChecked = .now
        // Read by an older version of PageLines: taken afresh, not compared.
        guard watch.readingVersion == PageLines.version else {
            watch.snapshot = lines.joined(separator: "\n")
            watch.readingVersion = PageLines.version
            return
        }
        if LaunchClock.isEnabled { print("WATCH \(watch.host): \(lines.count) lines, was \(old.count)") }
        // Far shorter than before: an error page or a wall, not the page. Keep the old reading.
        guard lines.joined().count * 3 >= old.joined().count else { return }
        watch.snapshot = lines.joined(separator: "\n")
        guard !old.isEmpty else { return }

        let before = Set(old), after = Set(lines)
        let added = lines.filter { !before.contains($0) }
        let removed = old.filter { !after.contains($0) }
        if LaunchClock.isEnabled { print("WATCH \(watch.host): \(added.count) added, \(removed.count) removed") }
        let verdict: (happened: Bool, notification: String)
        if watch.lookFor.isEmpty {
            // Anything new: new lines of real text, not a time or a counter ticking on.
            let ticked = Set(removed.map(withoutDigits))
            let news = added.filter { $0.count >= 30 && !ticked.contains(withoutDigits($0)) }
            guard !news.isEmpty else { return }
            verdict = await WatchJudge.news(in: news) ?? WatchJudge.guess(lookFor: "", added: news)
        } else {
            guard !added.isEmpty || !removed.isEmpty else { return }
            verdict = await WatchJudge.becameTrue(watch.lookFor, before: old, now: lines, removed: removed, added: added)
                ?? WatchJudge.guess(lookFor: watch.lookFor, added: added)
        }
        if LaunchClock.isEnabled { print("WATCH \(watch.host): \(verdict.happened ? "news" : "nothing"), \(verdict.notification)") }
        guard verdict.happened, !verdict.notification.isEmpty else { return }
        watch.lastNews = verdict.notification
        watch.lastNewsAt = .now
        WatchNotifications.post(title: watch.title.isEmpty ? watch.host : watch.title, body: verdict.notification,
                                url: watch.url, thread: watch.host)
    }

    private static func withoutDigits(_ line: String) -> String {
        String(line.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) })
    }
}

// MARK: Reading

/// A page as Notify Me compares it: one line per paragraph, list item or
/// heading, plus what shops publish for search engines (product, price, stock)
/// and the choices on the page (sizes), marked when they can't be picked.
/// Plain HTTP and text, no web view, so it can run in the background.
nonisolated enum PageLines {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        // Always the page as it is now: a cached copy would hide the change.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ","),
        ]
        return URLSession(configuration: configuration)
    }()

    /// Bumped when the way pages are read changes (2: link text on pages of
    /// boxes), so a watch re-reads instead of announcing the change as news.
    static let version = 2

    @concurrent static func fetch(_ url: URL) async -> [String]? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response.mimeType ?? "").contains("html") else { return nil }
        return lines(from: String(decoding: data, as: UTF8.self))
    }

    @concurrent static func parse(_ html: String) async -> [String] {
        lines(from: html)
    }

    /// Too little text to watch: the page writes it with scripts.
    static func isThin(_ lines: [String]) -> Bool {
        lines.joined().count < 300
    }

    static func lines(from html: String) -> [String] {
        var lines = productLines(html)
        for match in WebResearcher.matches(#"<option\b([^>]*)>([\s\S]*?)</option>"#, in: html) {
            let text = WebResearcher.plain(match[1])
            guard !text.isEmpty, text.count <= 60 else { continue }
            lines.append("Option: " + text + (match[0].contains("disabled") ? " (unavailable)" : ""))
        }
        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        for match in WebResearcher.matches(#"<(p|li|h[1-6]|td|dt|dd|figcaption)\b[^>]*>([\s\S]*?)</\1>"#, in: body) {
            let text = WebResearcher.plain(match[1])
            if text.count >= 3 { lines.append(String(text.prefix(400))) }
        }
        // A page built of divs and links (glas-slavonije.hr) has no paragraphs
        // or headings at all: its headlines are the links' text.
        if isThin(lines) {
            for match in WebResearcher.matches(#"<a\b[^>]*>([\s\S]*?)</a>"#, in: body) {
                let text = WebResearcher.plain(match[0])
                if (25...400).contains(text.count) { lines.append(text) }
            }
        }
        // Each line once, in page order, up to a long article's worth.
        var seen: Set<String> = [], kept: [String] = [], length = 0
        for line in lines where seen.insert(line).inserted {
            kept.append(line)
            length += line.count
            if length > 30_000 { break }
        }
        return kept
    }

    /// Products and offers from the page's JSON-LD: "Offer: Linen shirt M 39.95 EUR InStock".
    private static func productLines(_ html: String) -> [String] {
        var lines: [String] = []
        for block in WebResearcher.matches(#"<script[^>]*application/ld\+json[^>]*>([\s\S]*?)</script>"#, in: html) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(block[0].utf8)) else { continue }
            collect(json, product: nil, into: &lines)
        }
        return lines
    }

    private static func collect(_ node: Any, product: String?, into lines: inout [String]) {
        if let list = node as? [Any] {
            for item in list { collect(item, product: product, into: &lines) }
            return
        }
        guard let object = node as? [String: Any] else { return }
        let types = (object["@type"] as? [String]) ?? [(object["@type"] as? String) ?? ""]
        var product = product
        if types.contains(where: { $0.contains("Product") }), let name = object["name"] as? String {
            product = name
            lines.append("Product: " + name)
        }
        if types.contains(where: { $0.contains("Offer") }) {
            let price = [(object["price"] ?? object["lowPrice"]).map { "\($0)" }, object["priceCurrency"] as? String]
                .compactMap { $0 }.joined(separator: " ")
            let parts = [object["name"] as? String ?? product, price, (object["availability"] as? String).map(stock)]
            lines.append("Offer: " + parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        }
        for (key, value) in object where key != "@context" && (value is [Any] || value is [String: Any]) {
            collect(value, product: product, into: &lines)
        }
    }

    /// "https://schema.org/OutOfStock" in words, so the line reads like the page does.
    private static func stock(_ availability: String) -> String {
        let value = availability.split(separator: "/").last.map(String.init) ?? availability
        return switch value {
        case "InStock", "InStoreOnly", "OnlineOnly": "in stock"
        case "OutOfStock", "SoldOut": "sold out"
        case "LimitedAvailability": "few left"
        case "PreOrder", "PreSale": "pre-order"
        case "BackOrder": "on back order"
        case "Discontinued": "discontinued"
        default: value
        }
    }
}

/// Reads a page whose text its scripts write, in a web view nobody sees. Only
/// while roko is open: iOS doesn't run web views for an app in the background.
enum RenderedPage {
    static func lines(of url: URL) async -> [String]? {
        let webView = WebViewFactory.makeOffscreen()
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard await loader.finished(within: 20) else { return nil }
        // Loaded is not written: give its scripts a moment to fill it in.
        try? await Task.sleep(for: .seconds(2))
        guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else { return nil }
        return await PageLines.parse(html)
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func finished(within seconds: Double) async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish(false) }
            }
        }

        private func finish(_ loaded: Bool) {
            guard result == nil else { return }
            result = loaded
            continuation?.resume(returning: loaded)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(false)
        }
    }
}

// MARK: Judging

@Generable
nonisolated struct NewsCheck {
    // Asked "is it real news?", the model turned down a new event listing.
    @Guide(description: "False only if the new lines are just ads, times, counters or page furniture; true for anything a reader would want to know about")
    var isNews: Bool
    @Guide(description: "The notification: one short sentence. No preamble.")
    var notification: String
}

@Generable
nonisolated struct PageCheck {
    @Guide(description: "The line from the page that shows it, copied exactly; empty if no line does")
    var evidence: String
    @Guide(description: "True only if that line clearly shows it")
    var shows: Bool
    @Guide(description: "If it shows it, the notification: one short sentence. No preamble.")
    var notification: String
}

/// Whether a change is what you're waiting for, and the notification that
/// says so: Apple's on-device model, free and private, which apps may use for
/// a little while in the background too.
///
/// Asked "here's what was added and removed: did it happen?", the small model
/// mixed the two up and announced "back in stock" for a size that had just
/// sold out. So it answers plain questions about one version of the page at a
/// time, quoting the line it bases the answer on, and roko compares the answers.
enum WatchJudge {
    /// Anything new: whether the new lines are news, and the notification.
    static func news(in added: [String]) async -> (happened: Bool, notification: String)? {
        guard AppleModels.onDeviceAvailable else { return nil }
        let instructions = """
            You watch a web page for someone and tell them when something new appears on it: a new article, \
            post, event, product, listing or announcement. Ads, times, counters and layout are not news. You \
            get the lines that are new on the page. Write the notification as a person would say it: what it \
            is (a new article, a new event), then its headline or title in the page's own words. \
            \(language(of: added))
            """
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: instructions)
        let prompt = "New on the page:\n" + capped(added, 2_500)
        guard let response = try? await session.respond(to: prompt, generating: NewsCheck.self) else { return nil }
        return (response.content.isNews, response.content.notification)
    }

    /// Whether what you're waiting for is on the page now and wasn't before.
    static func becameTrue(_ lookFor: String, before: [String], now: [String], removed: [String], added: [String]) async
        -> (happened: Bool, notification: String)? {
        guard AppleModels.onDeviceAvailable else { return nil }
        guard let current = await check(lookFor, on: relevant(now, changed: added, to: lookFor)) else { return nil }
        guard current.shows else { return (false, "") }
        // Already so before: what changed was something else (a price, a photo).
        let earlier = await check(lookFor, on: relevant(before, changed: removed, to: lookFor))
        if earlier?.shows == true { return (false, "") }
        return (true, current.notification.isEmpty ? readable(current.evidence, 140) : current.notification)
    }

    /// One version of the page: does it show it, and on which line. A line
    /// the model quotes that isn't on the page doesn't count.
    private static func check(_ lookFor: String, on lines: [String]) async -> (shows: Bool, evidence: String, notification: String)? {
        let instructions = """
            You check a web page for someone. Answer only from the page's lines, never from what you know. \
            Lines starting "Offer:" give a product, its price and whether it's in stock; "Option:" lines are \
            choices on the page, and "(unavailable)" means that one can't be picked. Write the notification as \
            a person would say it, with the page's own specifics, in the way of "Back in stock: the blue \
            jacket in size 40, 89 EUR". \(language(of: [lookFor] + lines.prefix(8)))
            """
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: instructions)
        let prompt = "Does this page show: \(lookFor)\n\nThe page:\n" + capped(lines, 2_500)
        guard let content = try? await session.respond(to: prompt, generating: PageCheck.self).content else { return nil }
        let quoted = content.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let onPage = !quoted.isEmpty && lines.contains { $0.localizedCaseInsensitiveContains(quoted.prefix(40)) }
        return (content.shows && onPage, quoted, content.notification)
    }

    /// The lines worth showing the model: what changed, then what mentions
    /// what you're waiting for, then the page from the top (offers come first).
    private static func relevant(_ lines: [String], changed: [String], to lookFor: String) -> [String] {
        let words = keywords(lookFor)
        let mentioning = lines.filter { line in words.contains { line.lowercased().contains($0) } }
        var picked: [String] = [], seen: Set<String> = [], length = 0
        for line in changed + mentioning + lines where seen.insert(line).inserted {
            picked.append(line)
            length += line.count
            if length > 2_500 { break }
        }
        return picked
    }

    /// In the answer language, unless Apple's models write it badly (see WritingLanguage).
    private static func language(of lines: [String]) -> String {
        switch AnswerLanguage.target(for: lines.joined(separator: "\n")) {
        case .some(let language) where !language.appleWritesWell:
            "Write the notification in English, quoting names and headlines as they appear."
        case .some(let language): language.instruction
        case nil: "Write the notification in the language of the page."
        }
    }

    private static func keywords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init)
    }

    /// Without the model: new text for "anything new"; otherwise a new line
    /// that mentions what you're waiting for.
    static func guess(lookFor: String, added: [String]) -> (happened: Bool, notification: String) {
        if lookFor.isEmpty {
            guard let first = added.first else { return (false, "") }
            return (true, "New: " + readable(first, 120))
        }
        let words = keywords(lookFor)
        guard let line = added.first(where: { line in words.contains { line.lowercased().contains($0) } }) else {
            return (false, "")
        }
        return (true, readable(line, 140))
    }

    /// A line as it reads on the page, without the "Offer: " the reader adds.
    private static func readable(_ line: String, _ limit: Int) -> String {
        var line = line
        for mark in ["Offer: ", "Product: ", "Option: "] where line.hasPrefix(mark) { line.removeFirst(mark.count) }
        return String(line.prefix(limit))
    }

    private static func capped(_ lines: [String], _ limit: Int) -> String {
        String(lines.map { "- " + $0 }.joined(separator: "\n").prefix(limit))
    }
}

// MARK: Notifications and scheduling

enum WatchNotifications {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String, url: String, thread: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        content.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Opens the page a Notify Me notification is about, and shows notifications
/// while roko is open too.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Set once the browser is ready; a tap that launched roko waits for it.
    var open: ((URL) -> Void)? {
        didSet {
            if let pending, let open {
                self.pending = nil
                open(pending)
            }
        }
    }
    private var pending: URL?

    /// On the main actor, so it also finishes there: iOS completes the tap
    /// with UIKit work that must be on the main thread. Finished on a
    /// background thread (as a nonisolated method did), a tap stopped roko.
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: link) else { return }
        route(url)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func route(_ url: URL) {
        if let open { open(url) } else { pending = url }
    }
}

enum WatchScheduler {
    static let taskID = "com.growthstudio.roko.watch"

    /// Asks iOS to wake roko when the next page it can check in the background
    /// is due. iOS treats the time as "not before" and picks the moment itself.
    static func schedule(_ watches: [Watch]) {
        guard let next = watches.filter({ !$0.needsRendering }).map(\.nextCheck).min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = max(next, .now.addingTimeInterval(15 * 60))
        Task {
            do { try await BGTaskScheduler.shared.submitTaskRequest(request) } catch {
                if LaunchClock.isEnabled { print("WATCH can't book a background check: \(error)") }
            }
        }
    }

    static func schedule(in context: ModelContext) {
        schedule((try? context.fetch(FetchDescriptor<Watch>())) ?? [])
    }
}
