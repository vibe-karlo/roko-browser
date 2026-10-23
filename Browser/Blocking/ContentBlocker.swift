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
                let json = try await Task.detached(priority: .utility) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
                let list: WKContentRuleList? = try await store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: json)
                compiled[category] = list
            } catch {
                print("Blocklist \(category.rawValue) failed to compile: \(error)")
            }
        }
        LaunchClock.mark("ruleListsReady")

        // Drop lists left over from older app versions.
        for identifier in await store.availableIdentifiers() ?? [] where !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }

        controllers.allObjects.forEach { apply(to: $0, host: nil) }
    }

    private static func identifier(for category: Category, file: URL) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
