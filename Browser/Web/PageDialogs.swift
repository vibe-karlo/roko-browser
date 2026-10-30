import PassKit
import UIKit
import WebKit

/// What a page asks of you outside the page itself: its alert(), confirm()
/// and prompt() dialogs, opening another app, and files it hands over.
@MainActor
enum PageDialogs {
    /// Whatever is on top of the screen, to present over.
    static var top: UIViewController? {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?
            .rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Who's asking: the site's own name, so a page can't pass itself off as roko.
    static func title(for frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? "This page" : (URL(string: "https://\(frame.securityOrigin.host)")?.displayHost ?? frame.securityOrigin.host)
    }

    /// A page's dialog, answered by a button. Only for the page on screen: a
    /// tab out of sight gets the quiet answer (false, nothing typed).
    static func ask(_ webView: WKWebView, title: String, message: String,
                    buttons: [(String, UIAlertAction.Style)], field: String? = nil) async -> (index: Int, text: String?)? {
        // Nothing on screen to show it over, or something already being shown
        // or taken away: answered as if dismissed, so the page doesn't wait forever.
        guard webView.window != nil, let top, !top.isBeingDismissed, !top.isBeingPresented,
              !(top is UIAlertController) else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = PageAlert(title: title, message: message, preferredStyle: .alert)
            alert.answer = { continuation.resume(returning: $0) }
            if let field { alert.addTextField { $0.text = field } }
            for (index, (label, style)) in buttons.enumerated() {
                alert.addAction(UIAlertAction(title: label, style: style) { [weak alert] _ in
                    alert?.reply((index, alert?.textFields?.first?.text))
                })
            }
            top.present(alert, animated: true) {
                // Not shown after all (the screen under it went away): no answer.
                if alert.presentingViewController == nil { alert.reply(nil) }
            }
        }
    }

    /// A site's own sign-in (HTTP Basic or Digest), asked before the page
    /// loads, as routers and some work tools do: a name and a password, or nil.
    static func signIn(_ webView: WKWebView, host: String, secure: Bool,
                       name: String?) async -> (name: String, password: String)? {
        guard webView.window != nil, let top, !top.isBeingDismissed, !top.isBeingPresented,
              !(top is UIAlertController) else { return nil }
        let site = URL(string: "https://\(host)")?.displayHost ?? host
        let message = secure
            ? "\(site) asks for a user name and password."
            : "\(site) asks for a user name and password. The connection isn't private: they're sent as they are."
        return await withCheckedContinuation { continuation in
            let alert = PageAlert(title: "Sign in to \(site)", message: message, preferredStyle: .alert)
            alert.addTextField {
                $0.placeholder = "User name"
                $0.text = name
                $0.textContentType = .username
                $0.autocapitalizationType = .none
                $0.autocorrectionType = .no
            }
            alert.addTextField {
                $0.placeholder = "Password"
                $0.isSecureTextEntry = true
                $0.textContentType = .password
            }
            alert.answer = { answer in
                guard let answer, answer.index == 1 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (answer.text ?? "", alert.textFields?.last?.text ?? ""))
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak alert] _ in alert?.reply(nil) })
            alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
                alert?.reply((1, alert?.textFields?.first?.text))
            })
            top.present(alert, animated: true) {
                if alert.presentingViewController == nil { alert.reply(nil) }
            }
        }
    }

    /// A file the page handed over: a pass goes to Wallet, anything else to
    /// the share sheet (Save to Files, Calendar for an .ics, Books for a PDF).
    static func open(downloaded file: URL) {
        if file.pathExtension.lowercased() == "pkpass", let data = try? Data(contentsOf: file),
           let pass = try? PKPass(data: data), let add = PKAddPassesViewController(pass: pass) {
            top?.present(add, animated: true)
            return
        }
        ShareSheet.present([file])
    }
}

/// Delegate methods kept out of BrowserTab.swift: marked @objc, as WebKit
/// finds them by selector and they sit outside the extension that conforms.
/// An alert that answers exactly once: with the button tapped, or with
/// nothing when it goes away some other way (the sheet under it closed).
final class PageAlert: UIAlertController {
    var answer: (((index: Int, text: String?)?) -> Void)?

    func reply(_ value: (index: Int, text: String?)?) {
        guard let answer else { return }
        self.answer = nil
        answer(value)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // After a moment: a tapped button's handler may run just after this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in reply(nil) }
    }
}

extension BrowserTab {
    // MARK: Dialogs

    @objc func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await PageDialogs.ask(webView, title: PageDialogs.title(for: frame), message: message,
                                  buttons: [("OK", .default)])
    }

    @objc func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await PageDialogs.ask(webView, title: PageDialogs.title(for: frame), message: message,
                              buttons: [("Cancel", .cancel), ("OK", .default)])?.index == 1
    }

    @objc func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let answer = await PageDialogs.ask(webView, title: PageDialogs.title(for: frame), message: prompt,
                                                 buttons: [("Cancel", .cancel), ("OK", .default)],
                                                 field: defaultText ?? ""),
              answer.index == 1 else { return nil }
        return answer.text ?? ""
    }

    // MARK: Sign-in

    /// HTTP Basic and Digest sign-ins get roko's own dialog; everything else
    /// (certificates, servers' trust) is left to WebKit. Kept for this run of
    /// roko only, never saved.
    @objc func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest else {
            return (.performDefaultHandling, nil)
        }
        // Three wrong tries: the site's own error page.
        guard challenge.previousFailureCount < 3,
              let answer = await PageDialogs.signIn(webView, host: space.host,
                                                    secure: space.receivesCredentialSecurely,
                                                    name: challenge.proposedCredential?.user) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(user: answer.name, password: answer.password, persistence: .forSession))
    }

    // MARK: Other apps

    /// tel:, mailto:, maps, the App Store: a link you tapped opens at once.
    /// Anything else (a redirect, a script) asks first, and a tab out of
    /// sight never opens another app.
    func openOutside(_ url: URL, tapped: Bool, in webView: WKWebView) async {
        guard !tapped else {
            await UIApplication.shared.open(url)
            return
        }
        let app = switch url.scheme?.lowercased() {
        case "itms-apps", "itms-appss", "itms": "the App Store"
        case "tel": "Phone"
        case "mailto": "Mail"
        case "sms": "Messages"
        case "maps": "Maps"
        default: "another app"
        }
        let host = webView.url.map { $0.displayHost } ?? "This page"
        guard let answer = await PageDialogs.ask(webView, title: "Open \(app)?", message: "\(host) wants to open \(app).",
                                                 buttons: [("Cancel", .cancel), ("Open", .default)]),
              answer.index == 1 else { return }
        await UIApplication.shared.open(url)
    }

    // MARK: Downloads

    @objc func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        // An error (a sign-in you cancelled, a missing page) is shown, never
        // saved: its body is often empty and of no type at all.
        if let status = http?.statusCode, status >= 400 { return .allow }
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        // What WebKit can't show (a pass, a calendar file, a zip), or what the
        // site says is to be saved: a file, not a page.
        return navigationResponse.isForMainFrame && (attachment || !navigationResponse.canShowMIMEType) ? .download : .allow
    }

    /// Every file goes to Downloads, which keeps it going and lists it.
    @objc func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    @objc func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
        // A tab opened just for the file has nothing else in it: it goes, as in Safari.
        if webView.backForwardList.currentItem == nil { delegate?.tabOnlyDownloaded(self) }
    }
}
