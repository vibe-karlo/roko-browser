import Foundation
import WebKit

/// roko's side of the cookie pop-up scripts (Scripts/consent/bridge.js, built
/// from DuckDuckGo's Autoconsent): decides how each pop-up is answered, runs
/// the few rule steps that need the page's own scripts, and accepts cookies
/// on a site only when it doesn't work without them. A site where that
/// happened is remembered, and from then on accepted straight away.
@MainActor
final class ConsentHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ConsentHandler()
    static let world = WKContentWorld.world(name: "consent")
    static let handlerName = "consent"

    /// Why cookies are accepted on a site.
    enum Reason: String {
        /// Rejecting didn't get past the pop-up (a cookie wall).
        case wall
        /// After rejecting, the page held content back until cookies were accepted.
        case content
        /// You chose it in Site Settings.
        case chosen
    }

    /// Tells the browser, so it can say what happened ("Accepted cookies…").
    var onAccepted: ((_ host: String, _ reason: Reason) -> Void)?

    /// How often each page has been reloaded to unblock it, so a site that
    /// stays broken can't make roko reload it again and again.
    private var attempts: [String: Int] = [:]
    private let defaults = UserDefaults.standard
    private static let acceptKey = "consent.acceptedHosts"

    lazy var scripts: [WKUserScript] = [("consent-main", true), ("consent-frame", false)].compactMap { name, mainOnly in
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // At the start, so Autoconsent can keep a known pop-up hidden while it answers it.
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: mainOnly, in: Self.world)
    }

    // MARK: Per-site choice

    /// Whether cookies are accepted on this site, and why; nil means rejected.
    func acceptance(for host: String) -> Reason? {
        (defaults.dictionary(forKey: Self.acceptKey)?[Self.normalize(host)] as? String).flatMap(Reason.init)
    }

    func setAccepted(_ reason: Reason?, for host: String) {
        var hosts = defaults.dictionary(forKey: Self.acceptKey) ?? [:]
        hosts[Self.normalize(host)] = reason?.rawValue
        defaults.set(hosts, forKey: Self.acceptKey)
    }

    /// Every site where cookies are accepted, and why: for Settings → Sites.
    func acceptedSites() -> [String: Reason] {
        (defaults.dictionary(forKey: Self.acceptKey) as? [String: String] ?? [:]).compactMapValues(Reason.init)
    }

    private static func normalize(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Messages

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return (nil, nil) }
        // Decided for the site you're on, also when the pop-up sits in a frame.
        let host = webView.url?.host() ?? message.frameInfo.request.url?.host() ?? ""
        if LaunchClock.isEnabled {
            let state = type == "report" ? (body["state"].map { "\($0)" } ?? "").replacingOccurrences(of: "\n", with: " ").prefix(400) : ""
            print("CONSENT \(host)\(message.frameInfo.isMainFrame ? "" : " (frame)") \(type) \(body["cmp"] ?? "") \(body["result"] ?? "") \(state)")
        }

        switch type {
        case "popupFound":
            return (["type": acceptance(for: host) == nil ? "optOut" : "optIn"], nil)

        case "eval":
            // A rule step that needs the page's own script, such as a platform's API.
            let id = body["id"] as? String ?? ""
            let code = body["code"] as? String ?? "false"
            // At most a second: a platform API that never calls back (index.hr's)
            // left the step waiting, and Autoconsent, waiting for every rule, never
            // got as far as the Didomi pop-up right there on the page.
            let result = try? await webView.callAsyncJavaScript("""
                try {
                    return !!(await Promise.race([(async () => (\(code)))(), new Promise(done => setTimeout(() => done(false), 1000))]));
                } catch (e) { return false; }
                """, in: message.frameInfo, contentWorld: .page)
            return (["type": "evalResp", "id": id, "result": (result as? Bool) ?? false], nil)

        case "rokoWall":
            setAccepted(.wall, for: host)
            onAccepted?(host, .wall)
            return (["type": "optIn"], nil)

        case "rokoBlocked":
            if acceptance(for: host) == nil {
                setAccepted(.content, for: host)
                onAccepted?(host, .content)
            }
            // Through the platform's own API first: the content usually comes
            // back at once, with no reload.
            let accepted = (try? await webView.evaluateJavaScript(Self.acceptAll, in: nil, contentWorld: .page)) as? Int ?? 0
            if accepted > 0 { return (["type": "rokoRecheck"], nil) }
            await recover(webView, host: host)
            return (nil, nil)

        case "rokoPlatform":
            // Answered through the platform's API, as this site is answered.
            let accept = acceptance(for: host) != nil
            let answered = (try? await webView.evaluateJavaScript(accept ? Self.answerNotice(true) : Self.answerNotice(false),
                                                                  in: nil, contentWorld: .page)) as? Int ?? 0
            return (["answered": answered > 0, "accepted": accept && answered > 0], nil)

        case "rokoSaved":
            SavedStats.cookieBar(clicks: body["clicks"] as? Int ?? 1)
            return (nil, nil)

        case "rokoStillBlocked":
            await recover(webView, host: host)
            return (nil, nil)

        default:
            return (nil, nil)
        }
    }

    /// You asked for it ("Allow cookies" when a page kept being reloaded):
    /// cookies are accepted on this site from now on, an earlier "rejected"
    /// is turned into "accepted" where the site's platform allows it, and the
    /// page loads again with the site's consent platform no longer blocked.
    func acceptNow(in webView: WKWebView, host: String) async {
        setAccepted(.chosen, for: host)
        _ = try? await webView.evaluateJavaScript(Self.acceptAll, in: nil, contentWorld: .page)
        webView.reload()
    }

    /// Content still held back once cookies are accepted. First a plain
    /// reload: the site is now marked as accepted, so its consent platform is
    /// no longer blocked (ContentBlocker), shows its pop-up, and gets accepted.
    /// If that isn't enough, the site is keeping an earlier "rejected" in its
    /// cookies or storage and won't ask again: forget this site's data and
    /// load it afresh. Each at most once per page.
    private func recover(_ webView: WKWebView, host: String) async {
        guard let url = webView.url?.absoluteString else { return }
        let attempt = attempts[url, default: 0]
        attempts[url] = attempt + 1
        switch attempt {
        case 0:
            webView.reload()
        case 1:
            let store = webView.configuration.websiteDataStore
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types).filter { record in
                host == record.displayName || host.hasSuffix("." + record.displayName)
            }
            await store.removeData(ofTypes: types, for: records)
            webView.reload()
        default:
            break
        }
    }

    /// A platform's notice that's showing, answered through its API: for pages
    /// that scramble the names rules look for. Answers 1 if one was.
    private static func answerNotice(_ accept: Bool) -> String {
        """
        (() => {
          try {
            const d = window.Didomi;
            if (d && d.notice && typeof d.notice.isVisible === 'function' && d.notice.isVisible()) {
              \(accept ? "d.setUserAgreeToAll()" : "d.setUserDisagreeToAll()");
              if (d.notice.isVisible()) d.notice.hide();
              return 1;
            }
          } catch (e) {}
          return 0;
        })()
        """
    }

    /// "Accept all" through the consent platforms' own APIs, in the page's
    /// world. Answers how many it reached.
    private static let acceptAll = """
        (() => {
          let reached = 0;
          const tryIt = (test, act) => { try { if (test()) { act(); reached++; } } catch (e) {} };
          tryIt(() => window.OneTrust && OneTrust.AllowAll, () => OneTrust.AllowAll());
          tryIt(() => window.Cookiebot && Cookiebot.submitCustomConsent, () => Cookiebot.submitCustomConsent(true, true, true));
          tryIt(() => window.UC_UI && UC_UI.acceptAllConsents, () => UC_UI.acceptAllConsents());
          tryIt(() => window.__ucCmp && __ucCmp.acceptAllConsents, () => __ucCmp.acceptAllConsents());
          tryIt(() => window.Didomi && Didomi.setUserAgreeToAll, () => Didomi.setUserAgreeToAll());
          tryIt(() => window.klaro && klaro.getManager, () => { const m = klaro.getManager(); m.changeAll(true); m.saveAndApplyConsents(); });
          tryIt(() => typeof window.cmplz_accept_all === 'function', () => cmplz_accept_all());
          tryIt(() => window.tarteaucitron && tarteaucitron.userInterface, () => tarteaucitron.userInterface.respondAll(true));
          tryIt(() => window._iub && _iub.cs && _iub.cs.api && _iub.cs.api.acceptAll, () => _iub.cs.api.acceptAll());
          tryIt(() => typeof window.__cmp === 'function' && typeof __cmp('getCMPData') === 'object', () => __cmp('setConsent', 1));
          return reached;
        })()
        """
}
