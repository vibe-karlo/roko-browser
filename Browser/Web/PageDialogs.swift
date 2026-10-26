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

extension BrowserTab: WKDownloadDelegate {
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
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        // What WebKit can't show (a pass, a calendar file, a zip), or what the
        // site says is to be saved: a file, not a page.
        return navigationResponse.isForMainFrame && (attachment || !navigationResponse.canShowMIMEType) ? .download : .allow
    }

    @objc func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    @objc func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        // A folder of its own each time, so two files of one name don't collide.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        let file = folder.appendingPathComponent(name)
        downloads[ObjectIdentifier(download)] = file
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        PageDialogs.open(downloaded: file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        delegate?.tab(self, says: "Couldn't download it: \(error.localizedDescription)")
    }
}
