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

    private lazy var cookieScript: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "cookie-consent", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Sourcepoint and others render their banner in an iframe, so all frames.
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
    }()

    /// Didomi's pop-up style (Index, Jutarnji) has no reject button on its first
    /// screen, so ask Didomi itself to record "disagree to all". This has to run
    /// in the page's world to reach Didomi's API; it does nothing else.
    private let didomiScript = WKUserScript(source: """
        (window.didomiOnReady = window.didomiOnReady || []).push(function (Didomi) {
          if (Didomi.shouldConsentBeCollected()) Didomi.setUserDisagreeToAll();
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

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
        // The hiding index loads alongside the request lists, not before them.
        async let hidingIndex: Void = CosmeticFilter.shared.load()
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
        await hidingIndex

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

    private func apply(to controller: WKUserContentController, host: String?) {
        let allowed = host.map { isAllowed(host: $0) } ?? false
        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()
        guard !allowed else { return }

        for category in Category.allCases where isEnabled(category) {
            if let host, isAllowed(host: host, category: category) { continue }
            if let list = compiled[category] { controller.add(list) }
        }
        if isEnabled(.cookies), !(host.map { isAllowed(host: $0, category: .cookies) } ?? false) {
            if let cookieScript { controller.addUserScript(cookieScript) }
            controller.addUserScript(didomiScript)
        }
        // Element hiding is served per page rather than through the rule lists.
        if isEnabled(.ads) || isEnabled(.cookies) || isEnabled(.popups), let script = CosmeticFilter.shared.script {
            controller.addUserScript(script)
            controller.addScriptMessageHandler(CosmeticFilter.shared, contentWorld: CosmeticFilter.world,
                                               name: CosmeticFilter.handlerName)
        }
    }
}
