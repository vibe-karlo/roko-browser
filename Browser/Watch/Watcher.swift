import BackgroundTasks
import FoundationModels
import Network
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
            // Anything read means there's a connection; only with nothing read is it worth asking.
            let online = read.isEmpty ? await hasConnection() : true
            for (index, watch) in due.enumerated() {
                guard !Task.isCancelled else { break }
                // Deleted while this check waited: nothing more to read or tell.
                guard !isGone(watch) else { continue }
                var lines = read[index]
                if watch.needsRendering, let url = URL(string: watch.url) {
                    if let plain = lines, !PageLines.isThin(plain) {
                        // Readable plainly now: back to background checks, its
                        // reading taken afresh (rendered and plain text differ).
                        watch.needsRendering = false
                        watch.snapshot = plain.joined(separator: "\n")
                        watch.readingVersion = PageLines.version
                        watch.lastChecked = .now
                        watch.renderSucceeded()
                        try? context.save()
                        continue
                    } else {
                        // Plain text isn't this page's reading, so nothing to compare without this.
                        guard online, watch.mayRenderNow else { continue }
                        lines = await RenderedPage.lines(of: url)
                        guard !isGone(watch) else { continue }
                        if lines == nil { watch.renderFailed() }
                    }
                }
                // A page that reads plainly until it won't, with bot protection in front of
                // it, would never be checked again. Once a whole check has been missed it's
                // read rendered from now on, its reading taken afresh as above.
                if lines == nil, !watch.needsRendering, !inBackground, online, watch.mayRenderNow, let url = URL(string: watch.url),
                   force || watch.nextCheck.addingTimeInterval(Double(watch.everyHours) * 3600) <= .now {
                    let rendered = await RenderedPage.lines(of: url)
                    guard !isGone(watch) else { continue }
                    if let rendered, !PageLines.isThin(rendered) {
                        watch.needsRendering = true
                        watch.snapshot = rendered.joined(separator: "\n")
                        watch.readingVersion = PageLines.version
                        watch.lastChecked = .now
                        watch.renderSucceeded()
                        try? context.save()
                        continue
                    }
                    watch.renderFailed()
                }
                // Offline, or the page didn't load: it's still due, so next time. A hidden
                // read that failed is remembered, so coming back to roko doesn't repeat it.
                guard let lines else {
                    try? context.save()
                    continue
                }
                await compare(watch, with: lines)
                // Each as it's done: a page read in a web view takes up to 20
                // seconds, and roko left before then kept nothing, so the next
                // check compared with the old reading and told the same news again.
                try? context.save()
            }
        }
        // Read afresh: the list from the start may hold watches deleted since.
        WatchScheduler.schedule(in: context)
    }

    /// Deleted, saved or not. A deleted watch's other properties are not to be touched.
    private static func isGone(_ watch: Watch) -> Bool {
        watch.modelContext == nil || watch.isDeleted
    }

    /// Whether the phone has any way out, to tell a page that failed from no connection.
    private static func hasConnection() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            // It answers at once with the current path, then with changes; cancelled, there are none.
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "roko.watch.connection"))
        }
    }

    private static func compare(_ watch: Watch, with lines: [String]) async {
        watch.renderSucceeded()
        watch.lastChecked = .now
        // Read by an older version of PageLines: taken afresh, not compared.
        guard watch.readingVersion == PageLines.version else {
            watch.snapshot = lines.joined(separator: "\n")
            watch.readingVersion = PageLines.version
            return
        }
        let lookFor = watch.lookFor
        // Off the main thread: a check can land while a page is settling.
        let change = await Change.between(snapshot: watch.snapshot, and: lines, forAnythingNew: lookFor.isEmpty)
        guard !isGone(watch) else { return }
        let old = change.old
        if LaunchClock.isEnabled { print("WATCH \(watch.host): \(lines.count) lines, was \(old.count)") }
        // Far shorter than before: an error page or a wall, not the page. Keep the old reading.
        guard !change.isFarShorter else { return }
        watch.snapshot = change.reading
        guard !old.isEmpty else { return }

        let added = change.added, removed = change.removed
        if LaunchClock.isEnabled { print("WATCH \(watch.host): \(added.count) added, \(removed.count) removed") }
        let verdict: (happened: Bool, notification: String)
        if lookFor.isEmpty {
            guard !change.news.isEmpty else { return }
            verdict = await WatchJudge.news(in: change.news) ?? WatchJudge.guess(lookFor: "", added: change.news)
        } else {
            guard !added.isEmpty || !removed.isEmpty else { return }
            verdict = await WatchJudge.becameTrue(lookFor, before: old, now: lines, removed: removed, added: added)
                ?? WatchJudge.guess(lookFor: lookFor, added: added)
        }
        // The model can take a while: deleted meanwhile, it's no longer wanted.
        guard !isGone(watch) else { return }
        if LaunchClock.isEnabled { print("WATCH \(watch.host): \(verdict.happened ? "news" : "nothing"), \(verdict.notification)") }
        guard verdict.happened, !verdict.notification.isEmpty else { return }
        watch.lastNews = verdict.notification
        watch.lastNewsAt = .now
        WatchNotifications.post(title: watch.title.isEmpty ? watch.host : watch.title, body: verdict.notification,
                                url: watch.url, thread: watch.host)
    }

    /// What changed between the page's last reading and this one.
    private nonisolated struct Change: Sendable {
        let old: [String]
        let added: [String]
        let removed: [String]
        /// For "anything new": new lines of real text, not a time or a counter ticking on.
        let news: [String]
        let isFarShorter: Bool
        /// The new lines as a saved reading.
        let reading: String

        @concurrent static func between(snapshot: String, and lines: [String], forAnythingNew: Bool) async -> Change {
            let old = snapshot.split(separator: "\n").map(String.init)
            let before = Set(old), after = Set(lines)
            let added = lines.filter { !before.contains($0) }
            let removed = old.filter { !after.contains($0) }
            var news: [String] = []
            if forAnythingNew {
                let ticked = Set(removed.map(withoutTime))
                news = added.filter { $0.count >= 30 && !ticked.contains(withoutTime($0)) }
            }
            return Change(old: old, added: added, removed: removed, news: news,
                          isFarShorter: lines.joined().count * 3 < old.joined().count,
                          reading: lines.joined(separator: "\n"))
        }
    }

    /// A label saying how long ago, in English or Croatian: "Just now", "1m ago", "2 hr. ago",
    /// "prije 5 minuta", "upravo". Whole words like "3 hours" need their "ago".
    private nonisolated static let timeLabel = #"(just now|moments? ago|an? (minute|hour|day) ago|\d*\s*(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?)\.?\s*ago|\d+\s*(s|m|h|d|mins?|hrs?)\.?|upravo|maloprije|prije\s+(\d+\s*|nekoliko\s+)?(sek|min|sat|dan)\p{L}*\.?)"#

    /// A line without what ticks on: its digits, and a time label at its start, at its end
    /// or set apart by separators, since "Just now" becoming "1m ago" has no digit to take
    /// away. Only there: "Three hours of talks end" is news, not a label.
    private nonisolated static func withoutTime(_ line: String) -> String {
        var plain = line.lowercased()
        for pattern in [timeLabel + #"\s*$"#, "^\\s*" + timeLabel + #"\s*[:·|•,–-]"#, #"[·|•]\s*"# + timeLabel + #"\s*(?=[·|•])"#] {
            plain = plain.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return String(plain.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) })
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
        // All plain reads wait for each other: a page trickling in can't hold them for long.
        configuration.timeoutIntervalForResource = 30
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
    /// boxes; 3: no dialogs; 4: at a phone's width), so a watch re-reads instead of announcing the change as news.
    static let version = 4

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

    /// Enough for a page whose size is mostly inline scripts, and for what's left without them.
    private static let longestPage = 8 << 20, longestBody = 2 << 20

    static func lines(from whole: String) -> [String] {
        let html = TagScan(whole, atMost: longestPage)
        var lines = productLines(html)
        for option in html.elements(["option"]) {
            let text = WebResearcher.plain(option.inner)
            guard !text.isEmpty, text.count <= 60 else { continue }
            lines.append("Option: " + text + (option.attributes.contains("disabled") ? " (unavailable)" : ""))
        }
        let body = html.removing(["script", "style", "noscript", "svg", "nav", "header", "footer", "aside"], keeping: longestBody)
        for element in body.elements(["p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "td", "dt", "dd", "figcaption"]) {
            let text = WebResearcher.plain(element.inner)
            if text.count >= 3 { lines.append(String(text.prefix(400))) }
        }
        // A page built of divs and links (glas-slavonije.hr) has no paragraphs
        // or headings at all: its headlines are the links' text.
        if isThin(lines) {
            for link in body.elements(["a"]) {
                let text = WebResearcher.plain(link.inner)
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
    private static func productLines(_ html: TagScan) -> [String] {
        var lines: [String] = []
        for block in html.elements(["script"], holding: "application/ld+json") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(block.inner.utf8)) else { continue }
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

/// Finds elements in a page in one pass. HTML lets a page leave out `</li>`, `</p>` and `</td>`,
/// and a pattern looks to the end of the page for each one left out: 88 seconds on 1.1 MB. Here
/// where the next closing tag is gets remembered, so no stretch of the page is searched twice.
/// It finds what `<(p|li)\b[^>]*>([\s\S]*?)</\1>` finds, tag names as written (lowercase).
nonisolated struct TagScan {
    private let bytes: [UInt8]
    private static let tagStart = [UInt8(ascii: "<")], tagEnd = [UInt8(ascii: ">")]

    init(_ text: String, atMost limit: Int) {
        bytes = Array(text.utf8.prefix(limit))
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Every element with one of these names, in order, each searched for after the last ended.
    /// With `holding`, only opening tags with those words in them count.
    func elements(_ names: [String], holding needed: String? = nil) -> [(attributes: String, inner: String)] {
        let tags = names.map { (open: Array("<\($0)".utf8), close: Array("</\($0)>".utf8)) }
        let needle = needed.map { Array($0.utf8) }
        var found: [(attributes: String, inner: String)] = []
        bytes.withUnsafeBufferPointer { page in
            var nextEnd = -1
            var nextClose = [Int](repeating: -1, count: tags.count)
            var at = 0
            while let start = Self.find(Self.tagStart, in: page, from: at) {
                at = start + 1
                guard let which = tags.firstIndex(where: { Self.opens($0.open, at: start, in: page) }) else { continue }
                let afterName = start + tags[which].open.count
                if nextEnd < afterName {
                    nextEnd = Self.find(Self.tagEnd, in: page, from: afterName) ?? page.count
                }
                // No tag finishes from here on.
                guard nextEnd < page.count else { break }
                if let needle, Self.find(needle, in: UnsafeBufferPointer(rebasing: page[afterName..<nextEnd]), from: 0) == nil { continue }
                let innerStart = nextEnd + 1
                if nextClose[which] < innerStart {
                    nextClose[which] = Self.find(tags[which].close, in: page, from: innerStart) ?? page.count
                }
                let innerEnd = nextClose[which]
                guard innerEnd < page.count else { continue }
                found.append((Self.text(page, afterName..<nextEnd), Self.text(page, innerStart..<innerEnd)))
                at = innerEnd + tags[which].close.count
            }
        }
        return found
    }

    /// The page without these elements, each a space in its place, whatever its case. Unlike
    /// `elements`, what comes after the name needn't finish the tag. Cut to `limit` at the end.
    func removing(_ names: [String], keeping limit: Int) -> TagScan {
        var kept = bytes
        for name in names {
            let open = Array("<\(name)".utf8), close = Array("</\(name)>".utf8)
            let lower = kept.map { (65...90).contains($0) ? $0 + 32 : $0 }
            var output: [UInt8] = []
            output.reserveCapacity(kept.count)
            var copied = 0
            lower.withUnsafeBufferPointer { page in
                var at = 0
                while let start = Self.find(open, in: page, from: at) {
                    at = start + 1
                    guard Self.opens(open, at: start, in: page) else { continue }
                    // None closes: nor will any later one.
                    guard let end = Self.find(close, in: page, from: start + open.count) else { break }
                    output.append(contentsOf: kept[copied..<start])
                    output.append(UInt8(ascii: " "))
                    copied = end + close.count
                    at = copied
                }
            }
            output.append(contentsOf: kept[copied...])
            kept = output
        }
        if kept.count > limit { kept.removeLast(kept.count - limit) }
        return TagScan(bytes: kept)
    }

    /// `<name` here, and the name ends here (the pattern's `\b`).
    private static func opens(_ open: [UInt8], at start: Int, in page: UnsafeBufferPointer<UInt8>) -> Bool {
        let end = start + open.count
        guard end <= page.count, memcmp(page.baseAddress! + start, open, open.count) == 0 else { return false }
        guard end < page.count else { return true }
        let next = page[end]
        let isWord = next >= 0x80 || next == UInt8(ascii: "_") || (48...57).contains(next) || (65...90).contains(next) || (97...122).contains(next)
        return !isWord
    }

    private static func find(_ needle: [UInt8], in page: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from < page.count, let base = page.baseAddress else { return nil }
        guard let hit = memmem(base + from, page.count - from, needle, needle.count) else { return nil }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
    }

    private static func text(_ page: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: page[range]), as: UTF8.self)
    }
}

/// Reads a page whose text its scripts write, in a web view nobody sees. Only
/// while roko is open: iOS doesn't run web views for an app in the background.
enum RenderedPage {
    /// A web view out of any window, at a phone's size: at no width at all, a page that
    /// lays itself out by width writes less (Reuters: 117 lines of 141).
    private static func makeView() -> WKWebView {
        let webView = WebViewFactory.makeOffscreen()
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return webView
    }

    static func lines(of url: URL) async -> [String]? {
        let webView = makeView()
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard await loader.finished(within: 20) else {
            webView.stopLoading()
            return nil
        }
        // Loaded is not written: give its scripts a moment to fill it in.
        // A page that moves itself on starts over: read halfway, or as the page it
        // left, its next reading would differ and be announced as news.
        let giveUp = Date.now.addingTimeInterval(15)
        var still = Date.now
        while Date.now < giveUp, Date.now.timeIntervalSince(still) < 2 {
            let parsing = try? await webView.evaluateJavaScript("document.readyState") as? String == "loading"
            if (webView.isLoading && loader.isMoving) || parsing == true { still = .now }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let html = try? await webView.evaluateJavaScript(withoutDialogs) as? String else { return nil }
        return await PageLines.parse(html)
    }

    /// The page without its dialogs, shut or showing. A cookie notice or a sign-in box
    /// isn't the page, and comes and goes: nytimes.com's consent script writes its
    /// notice in stages, hidden, so one reading had none of it and the next had it all,
    /// which was announced as news.
    private static let withoutDialogs = """
    (() => {
      const page = document.documentElement.cloneNode(true);
      for (const dialog of page.querySelectorAll("dialog,[role=dialog],[role=alertdialog],[aria-modal=true]")) dialog.remove();
      return page.outerHTML;
    })()
    """

    /// A newsletter's text, by Readability. Nothing it points at is loaded and none
    /// of its scripts run: a tracking pixel doesn't fire from being read here.
    static func readable(html: String) async -> ReadablePage? {
        let webView = WebViewFactory.makeOffscreen()
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let rule = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "roko-mail-text", encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#) {
            webView.configuration.userContentController.add(rule)
        }
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.loadHTMLString(html, baseURL: nil)
        _ = await loader.finished(within: 8)
        return try? await PageReader.read(webView, forMail: true)
    }

    /// The article on a page, by Readability, off screen: its scripts run, and
    /// the app's blocking applies. Still read if the page never quite finishes.
    static func readable(of url: URL) async -> ReadablePage? {
        let webView = makeView()
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.load(URLRequest(url: url))
        let finished = await loader.finished(within: 15)
        // Past where a page moves itself on: outside the UK, bbc.co.uk goes to
        // bbc.com about a second after loading, and its own text reads shorter.
        if finished { try? await Task.sleep(for: .seconds(1.5)) }
        defer { webView.stopLoading() }
        // Too early isn't the end of it while the page is still coming: a move
        // ends a read under way and leaves half a page parsed, which would read
        // as an article, and a slow start leaves nothing at all to read yet.
        let giveUp = Date.now.addingTimeInterval(15)
        while true {
            let state = try? await webView.evaluateJavaScript("document.readyState") as? String
            let settling = (webView.isLoading && loader.isMoving) || state == "loading"
            let outOfTime = Date.now >= giveUp
            if !settling || outOfTime, let page = try? await PageReader.read(webView) { return page }
            guard webView.isLoading, !outOfTime else { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?
        /// A navigation has begun and its page hasn't replaced the one showing.
        private(set) var isMoving = false

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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isMoving = true }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { isMoving = false }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isMoving = false
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
