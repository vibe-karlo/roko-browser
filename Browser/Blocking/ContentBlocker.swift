import Foundation
import WebKit

/// Ad, tracker, cookie-banner and pop-up blocking. Requests are blocked by
/// WebKit's native content rule lists; element hiding is served per page by
/// CosmeticFilter.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    enum Category: String, CaseIterable, Identifiable {
        case ads, privacy, cookies, popups
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ads: "Ads"
            case .privacy: "Trackers"
            case .cookies: "Cookie banners"
            case .popups: "Pop-ups"
            }
        }
    }

    private let store = WKContentRuleListStore.default()!
    private var compiled: [Category: WKContentRuleList] = [:]
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let defaults = UserDefaults.standard

    /// Lists and the hiding index, loaded once. Page loads wait on this, so a
    /// page opened during the first launch's compile is still filtered.
    private lazy var preparation = Task { await load() }

    private init() {}

    // MARK: Settings

    func isEnabled(_ category: Category) -> Bool {
        defaults.object(forKey: "block.\(category.rawValue)") as? Bool ?? true
    }

    func setEnabled(_ category: Category, _ enabled: Bool) {
        defaults.set(enabled, forKey: "block.\(category.rawValue)")
        settingsChanged()
    }

    /// Blocking settings changed, here or on another device (SettingsSync).
    func settingsChanged() {
        controllers.allObjects.forEach { apply(to: $0, host: nil) }
    }

    /// Whether a site is exempt from all blocking, or with a category, from just that one.
    func isAllowed(host: String, category: Category? = nil) -> Bool {
        allowedHosts(category).contains(Self.normalize(host))
    }

    /// Tells the browser, so it can say what happened ("Ads allowed…").
    var onAdsAllowed: ((_ host: String) -> Void)?

    /// A site shows nothing while its ads are blocked (BILD's anti-adblock empties the
    /// page). Two steps, each followed by a reload, and each only if the last wasn't enough:
    /// first its ad scripts may load, which is usually all the anti-adblock checks, while the
    /// ads' pictures, frames and videos stay blocked. Then, since a page beats a blocked ad,
    /// its ads are let through, here only. Trackers, cookies and pop-ups stay handled, and
    /// Site Settings can undo it.
    func pageRefusedToShow(on host: String, reloading webView: WKWebView) async {
        guard !isAllowed(host: host, category: .ads) else { return }
        if LaunchClock.isEnabled { print("REFUSED \(host) softAlready=\(softHosts.contains(Self.normalize(host)))") }
        if softHosts.contains(Self.normalize(host)) {
            setSoft(host: host, false)
            setAllowed(host: host, category: .ads, true)
            onAdsAllowed?(host)
        } else {
            await compileSoftAds()
            guard softAds != nil else {
                setAllowed(host: host, category: .ads, true)
                onAdsAllowed?(host)
                apply(to: webView.configuration.userContentController, host: host)
                webView.reload()
                return
            }
            setSoft(host: host, true)
        }
        apply(to: webView.configuration.userContentController, host: host)
        webView.reload()
    }

    /// A page that keeps crashing may be crashing over what roko changes on it. Until roko is
    /// next opened it's loaded without those changes, its requests still blocked. True the
    /// first time a site asks: after that there's nothing left to try.
    func loadGently(host: String) -> Bool { gentleHosts.insert(Self.normalize(host)).inserted }
    private var gentleHosts = Set<String>()

    private var softHosts: Set<String> { Set(defaults.stringArray(forKey: Self.softKey) ?? []) }
    private static let softKey = "block.ads.softHosts"

    private func setSoft(host: String, _ soft: Bool) {
        var hosts = softHosts
        if soft { hosts.insert(Self.normalize(host)) } else { hosts.remove(Self.normalize(host)) }
        defaults.set(Array(hosts), forKey: Self.softKey)
    }

    /// The ads list, with its ad scripts and their requests let through. Few people need it,
    /// so it's only compiled once a site asks for it, and kept after that.
    private var softAds: WKContentRuleList?

    private func compileSoftAds() async {
        guard softAds == nil else { return }
        let identifier = "ads-soft-\(Self.listsVersion)"
        if let list = try? await store.contentRuleList(forIdentifier: identifier) {
            softAds = list
            return
        }
        guard let url = Bundle.main.url(forResource: "ads", withExtension: "json") else { return }
        let hosts = Bundle.main.url(forResource: "ads-hosts", withExtension: "txt")
        let json = try? await Task.detached(priority: .userInitiated) { () -> String in
            let rules = try Self.rules(json: url, hosts: hosts).trimmingCharacters(in: .whitespacesAndNewlines)
            return rules.dropLast() + #",{"trigger":{"url-filter":".*","resource-type":["script","fetch"]},"action":{"type":"ignore-previous-rules"}}]"#
        }.value
        guard let json else { return }
        softAds = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
    }

    func setAllowed(host: String, category: Category? = nil, _ allowed: Bool) {
        var hosts = allowedHosts(category)
        if allowed { hosts.insert(Self.normalize(host)) } else { hosts.remove(Self.normalize(host)) }
        defaults.set(Array(hosts), forKey: Self.allowKey(category))
    }

    /// Sites where blocking is off, all of it or one kind, and what: for Settings → Sites.
    func allowances() -> [String: [String]] {
        var sites: [String: [String]] = [:]
        for host in allowedHosts(nil) { sites[host, default: []].append("Nothing blocked") }
        for category in Category.allCases {
            for host in allowedHosts(category) { sites[host, default: []].append("\(category.title) allowed") }
        }
        return sites
    }

    /// Blocking as everywhere else again, every kind.
    func forgetAllowances(for host: String) {
        setSoft(host: host, false)
        setAllowed(host: host, false)
        for category in Category.allCases { setAllowed(host: host, category: category, false) }
    }

    private func allowedHosts(_ category: Category?) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.allowKey(category)) ?? [])
    }

    private static func allowKey(_ category: Category?) -> String {
        category.map { "block.\($0.rawValue).allowedHosts" } ?? "block.allowedHosts"
    }

    private static func normalize(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Lifecycle

    /// Loads the compiled lists from WebKit's cache, compiling from the bundle
    /// only when the bundled JSON changed. A cached lookup takes about a millisecond.
    /// Safe to call many times; every caller waits for the same single load.
    func prepare() async {
        await preparation.value
    }

    /// The lists are loaded and in place.
    private(set) var isReady = false

    /// Waits for the lists, but no longer than `limit`: a compile that's slow
    /// (or stuck) must never hold a page that was asked for. Past the limit the
    /// page loads, and blocking joins it as soon as the lists are ready.
    func prepare(within limit: Duration) async {
        guard !isReady else { return }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = {
                guard !once.done else { return }
                once.done = true
                continuation.resume()
            }
            Task { await self.prepare(); resume() }
            Task { try? await Task.sleep(for: limit); resume() }
        }
    }

    private final class Once { var done = false }

    /// Asks WebKit for the lists now. It finds them on its own queue while the
    /// main thread sets up the app, so they're ready the moment a page wants them.
    func lookUpEarly() {
        for category in Category.allCases {
            let identifier = "\(category.rawValue)-\(Self.listsVersion)"
            let (found, reply) = AsyncStream.makeStream(of: WKContentRuleList?.self)
            earlyLookups[identifier] = found
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                reply.yield(list)
                reply.finish()
            }
        }
    }

    private var earlyLookups: [String: AsyncStream<WKContentRuleList?>] = [:]

    private func load() async {
        // The hiding indexes load alongside the request lists; pages only wait
        // for the request lists, so nothing loads unfiltered.
        Task { await CosmeticFilter.shared.load() }
        var current: Set<String> = []
        for category in Category.allCases {
            guard let url = Bundle.main.url(forResource: category.rawValue, withExtension: "json") else { continue }
            let identifier = "\(category.rawValue)-\(Self.listsVersion)"
            current.insert(identifier)

            if let early = earlyLookups[identifier] {
                for await list in early where list != nil {
                    compiled[category] = list
                }
                if compiled[category] != nil { continue }
            } else if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                compiled[category] = list
                continue
            }
            do {
                let hosts = Bundle.main.url(forResource: "\(category.rawValue)-hosts", withExtension: "txt")
                let json = try await Task.detached(priority: .utility) {
                    try Self.rules(json: url, hosts: hosts)
                }.value
                let list: WKContentRuleList? = try await store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: json)
                compiled[category] = list
            } catch {
                print("Blocklist \(category.rawValue) failed to compile: \(error)")
            }
        }
        LaunchClock.mark("ruleListsReady")
        isReady = true

        // Drop lists left over from older app versions.
        current.insert("ads-soft-\(Self.listsVersion)")
        if !softHosts.isEmpty { await compileSoftAds() }
        for identifier in await store.availableIdentifiers() ?? [] where !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }

        controllers.allObjects.forEach { apply(to: $0, host: nil) }
    }

    /// A list's rules as WebKit takes them: its plain hosts (shipped one per
    /// line, a fifth of the size as JSON) made into block rules, then the rest,
    /// whose exceptions must come last. Only when compiling, once per update.
    nonisolated static func rules(json: URL, hosts: URL?) throws -> String {
        let rest = try String(contentsOf: json, encoding: .utf8)
        guard let hosts, let text = try? String(contentsOf: hosts, encoding: .utf8) else { return rest }
        var out = "["
        out.reserveCapacity(rest.utf8.count + text.utf8.count * 4)
        var any = false
        for host in text.split(separator: "\n") where !host.isEmpty {
            if any { out += "," }
            any = true
            out += #"{"trigger":{"url-filter":"^[^:]+://+([^/]+\\.)?"#
            out += host.replacingOccurrences(of: ".", with: #"\\."#)
            out += #"[/:?&=]"},"action":{"type":"block"}}"#
        }
        let others = rest.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()  // without its "["
        return out + (others.first == "]" || !any ? "" : ",") + others
    }

    /// From the lists' own contents (build_blocklists.py), not the build: an update
    /// with the same lists keeps their compiled form and opens without compiling.
    private static let listsVersion = Bundle.main.url(forResource: "version", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"

    // MARK: Wiring

    func install(in controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller, host: nil)
    }

    /// Called before each main-frame navigation. Rule lists can't be scoped per
    /// site from outside, so an allowed site gets a controller with no lists.
    func configure(_ controller: WKUserContentController, for host: String?) {
        apply(to: controller, host: host)
    }

    /// What each controller was last set up for, so a navigation that needs
    /// the same setup (most of them) doesn't tear it down and resend it.
    private let applied = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()

    func apply(to controller: WKUserContentController, host: String?) {
        let allowed = host.map { isAllowed(host: $0) } ?? false
        let exempt = Category.allCases.filter { category in
            !isEnabled(category) || host.map { isAllowed(host: $0, category: category) } == true
        }
        // A site that needs its cookies accepted gets its consent platform
        // back: the cookie list blocks many of them, and a blocked one can't
        // be accepted. Its pop-up is still answered, with accept.
        let acceptsCookies = host.map { ConsentHandler.shared.acceptance(for: $0) != nil } ?? false
        let dark = ForceDark.applies(to: host)
        let softAdsHere = softAds != nil && host.map { softHosts.contains(Self.normalize($0)) } == true
        // Only where its ads are blocked: it's what those ads' absence brought on.
        let gentle = host.map { gentleHosts.contains(Self.normalize($0)) } == true
        let siteCalls = allowed || gentle || exempt.contains(.ads) ? nil : SiteScripts.calls(for: host)
        let signature = "\(allowed)|\(exempt.map(\.rawValue).joined(separator: ","))|\(acceptsCookies)|\(compiled.count)|\(dark)|\(softAdsHere)|\(siteCalls ?? "")|\(gentle)"
        if applied.object(forKey: controller) as String? == signature { return }
        applied.setObject(signature as NSString, forKey: controller)

        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()
        // Only the blocker's own handler: page translation keeps its own.
        controller.removeScriptMessageHandler(forName: CosmeticFilter.handlerName, contentWorld: CosmeticFilter.world)
        controller.removeScriptMessageHandler(forName: ConsentHandler.handlerName, contentWorld: ConsentHandler.world)
        // Not blocking, so it stays on sites you allow too.
        if let script = BackgroundPlay.script { controller.addUserScript(script) }
        if let script = PageWatch.script { controller.addUserScript(script) }
        if dark, let script = ForceDark.script { controller.addUserScript(script) }
        guard !allowed else { return }

        if let siteCalls, let script = SiteScripts.script(calls: siteCalls) { controller.addUserScript(script) }
        for category in Category.allCases where isEnabled(category) {
            if let host, isAllowed(host: host, category: category) { continue }
            if category == .cookies, acceptsCookies { continue }
            if category == .ads, softAdsHere, let softAds { controller.add(softAds); continue }
            if let list = compiled[category] { controller.add(list) }
        }
        // Cookie pop-ups are answered, not just hidden: hidden, a site keeps
        // asking, and often keeps the page locked or its content held back.
        if isEnabled(.cookies), !(host.map { isAllowed(host: $0, category: .cookies) } ?? false) {
            ConsentHandler.shared.scripts.forEach(controller.addUserScript)
            controller.addScriptMessageHandler(ConsentHandler.shared, contentWorld: ConsentHandler.world,
                                               name: ConsentHandler.handlerName)
        }
        // Element hiding is served per page rather than through the rule lists.
        if !gentle, isEnabled(.ads) || isEnabled(.cookies) || isEnabled(.popups), let script = CosmeticFilter.shared.script {
            controller.addUserScript(script)
            controller.addScriptMessageHandler(CosmeticFilter.shared, contentWorld: CosmeticFilter.world,
                                               name: CosmeticFilter.handlerName)
        }
    }
}
