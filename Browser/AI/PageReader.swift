import Foundation
import WebKit

struct ReadablePage: Sendable {
    let title: String
    let site: String
    /// Paragraphs, headings and list items, separated by blank lines.
    let text: String
    /// False for homepages and index pages, where "the article" is a list of links.
    let isArticle: Bool
}

/// Pulls the article text out of a page with Mozilla's Readability, loaded only
/// when asked for, in its own script world so the page can't interfere.
enum PageReader {
    private static let readability: String = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    // Readability's textContent glues adjacent blocks together ("…tontos?Silvia Leal…"),
    // so walk its cleaned HTML and keep each block on its own.
    private static let extract = """
    let article = null;
    try { article = new Readability(document.cloneNode(true)).parse(); } catch (e) {}
    const blocks = [];
    if (article && article.content) {
      const doc = new DOMParser().parseFromString(article.content, "text/html");
      const selector = "h1,h2,h3,h4,p,li,blockquote,pre,figcaption";
      for (const el of doc.body.querySelectorAll(selector)) {
        if (el.parentElement && el.parentElement.closest(selector)) continue;
        const text = el.textContent.replace(/\\s+/g, " ").trim();
        if (text) blocks.push(text);
      }
    }
    const longBlocks = blocks.filter(b => b.length > 80).length;
    const isArticle = longBlocks >= 3;
    const text = blocks.length ? blocks.join("\\n\\n") : (document.body ? document.body.innerText : "");
    return {
      title: (article && article.title) || document.title,
      site: (article && article.siteName) || location.hostname,
      text: text,
      isArticle: isArticle
    };
    """

    static func read(_ webView: WKWebView) async throws -> ReadablePage {
        let result = try await webView.callAsyncJavaScript(
            readability + "\n" + extract, contentWorld: .world(name: "reader"))
        guard let fields = result as? [String: Any] else {
            throw ClaudeError(message: "This page has no readable text.")
        }
        let text = (fields["text"] as? String ?? "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 200 else { throw ClaudeError(message: "This page has too little text to summarize.") }
        return ReadablePage(title: fields["title"] as? String ?? "", site: fields["site"] as? String ?? "",
                            text: String(text.prefix(200_000)), isArticle: fields["isArticle"] as? Bool ?? false)
    }
}
