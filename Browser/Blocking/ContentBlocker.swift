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

    private func load() async {
        // The hiding indexes load alongside the request lists; pages only wait
        // for the request lists, so nothing loads unfiltered.
        Task { await CosmeticFilter.shared.load() }
        var current: Set<String> = []
        for category in Category.allCases {
            guard let url = Bundle.main.url(forResource: category.rawValue, withExtension: "json") else { continue }
            let identifier = Self.identifier(for: category, file: url)
            current.insert(identifier)

            if let list = try? await store.contentRuleList(forIdentifier: identifier) {
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

    private static func identifier(for category: Category, file: URL) -> String {
        let hosts = Bundle.main.url(forResource: "\(category.rawValue)-hosts", withExtension: "txt")
        let size = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            + ((try? hosts?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(category.rawValue)-\(build)-\(size)"
    }

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

    private func apply(to controller: WKUserContentController, host: String?) {
        let allowed = host.map { isAllowed(host: $0) } ?? false
        let exempt = Category.allCases.filter { category in
            !isEnabled(category) || host.map { isAllowed(host: $0, category: category) } == true
        }
        // A site that needs its cookies accepted gets its consent platform
        // back: the cookie list blocks many of them, and a blocked one can't
        // be accepted. Its pop-up is still answered, with accept.
        let acceptsCookies = host.map { ConsentHandler.shared.acceptance(for: $0) != nil } ?? false
        let signature = "\(allowed)|\(exempt.map(\.rawValue).joined(separator: ","))|\(acceptsCookies)|\(compiled.count)"
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
        guard !allowed else { return }

        for category in Category.allCases where isEnabled(category) {
            if let host, isAllowed(host: host, category: category) { continue }
            if category == .cookies, acceptsCookies { continue }
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
        if isEnabled(.ads) || isEnabled(.cookies) || isEnabled(.popups), let script = CosmeticFilter.shared.script {
            controller.addUserScript(script)
            controller.addScriptMessageHandler(CosmeticFilter.shared, contentWorld: CosmeticFilter.world,
                                               name: CosmeticFilter.handlerName)
        }
    }
}
