import WebKit

/// The page menu's Save as PDF: runs only when asked for.
enum PagePDF {
    /// The whole page as a PDF, as WebKit draws it, made away from the main
    /// thread. It goes to Downloads, like any file from a page.
    static func save(_ webView: WKWebView, title: String) async -> Bool {
        let dark = ForceDark.applies(to: webView.url?.host())
        if dark { await ForceDark.pause(webView, true) }
        let data = try? await webView.pdf()
        if dark { await ForceDark.pause(webView, false) }
        guard let data else { return false }
        return Downloads.shared.add(data, named: "\(title.isEmpty ? "Page" : title).pdf", from: webView.url)
    }
}
