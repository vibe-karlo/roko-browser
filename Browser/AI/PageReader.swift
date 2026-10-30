import Foundation
import WebKit

struct ReadablePage: Sendable {
    let title: String
    let site: String
    /// Paragraphs, headings and list items, separated by blank lines.
    let text: String
    /// False for homepages and index pages, where "the article" is a list of links.
    let isArticle: Bool
    /// The language the page says it's in (`<html lang>`), when it says.
    var declaredLanguage: String? = nil
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
      isArticle: isArticle,
      lang: document.documentElement.lang || ""
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
                            text: String(text.prefix(200_000)), isArticle: fields["isArticle"] as? Bool ?? false,
                            declaredLanguage: (fields["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The article as Markdown, for notes or an AI chat: its title, headings,
    /// paragraphs, lists, quotes, code and links, without the page around it.
    /// The whole page's text when it has no article.
    private static let markdownScript = """
    let article = null;
    try { article = new Readability(document.cloneNode(true)).parse(); } catch (e) {}
    const root = article && article.content
      ? new DOMParser().parseFromString(article.content, "text/html").body
      : document.body;
    // The marks hug the words; the spaces around them stay outside.
    const wrap = (text, mark) => text.trim()
      ? (/^\\s/.test(text) ? " " : "") + mark + text.trim() + mark + (/\\s$/.test(text) ? " " : "")
      : text;
    const inline = (node) => {
      let out = "";
      for (const child of node.childNodes) {
        if (child.nodeType === 3) { out += child.textContent.replace(/\\s+/g, " "); continue; }
        if (child.nodeType !== 1) continue;
        const tag = child.tagName, text = inline(child);
        if (tag === "BR") out += "  \\n";
        else if (tag === "STRONG" || tag === "B") out += wrap(text, "**");
        else if (tag === "EM" || tag === "I") out += wrap(text, "*");
        else if (tag === "CODE") out += "`" + child.textContent + "`";
        else if (tag === "A" && child.href && /^https?:/.test(child.href) && text.trim()) out += "[" + text.trim() + "](" + child.href + ")";
        else if (tag === "IMG") continue;
        else out += text;
      }
      return out;
    };
    const blocks = [];
    const walk = (node, depth) => {
      for (const el of node.children) {
        const tag = el.tagName;
        if (/^H[1-6]$/.test(tag)) blocks.push("#".repeat(Math.max(+tag[1], 2)) + " " + inline(el).trim());
        else if (tag === "P" || tag === "FIGCAPTION") { const t = inline(el).trim(); if (t) blocks.push(t); }
        else if (tag === "UL" || tag === "OL") {
          let n = 1;
          const lines = [];
          for (const li of el.children) {
            if (li.tagName !== "LI") continue;
            const t = inline(li).trim();
            if (t) lines.push("  ".repeat(depth) + (tag === "OL" ? (n++) + ". " : "- ") + t);
          }
          if (lines.length) blocks.push(lines.join("\\n"));
        }
        else if (tag === "BLOCKQUOTE") { const t = inline(el).trim(); if (t) blocks.push(t.split("\\n").map(l => "> " + l).join("\\n")); }
        else if (tag === "PRE") blocks.push("```\\n" + el.textContent.replace(/\\n$/, "") + "\\n```");
        else if (tag === "HR") blocks.push("---");
        else if (!["SCRIPT", "STYLE", "NAV", "FOOTER", "ASIDE", "FORM", "BUTTON", "SVG", "NOSCRIPT"].includes(tag)) walk(el, depth);
      }
    };
    walk(root, 0);
    const title = (article && article.title) || document.title;
    return "# " + title.trim() + "\\n\\n" + location.href + "\\n\\n" + blocks.join("\\n\\n");
    """

    static func markdown(_ webView: WKWebView) async -> String? {
        let result = try? await webView.callAsyncJavaScript(
            readability + "\n" + markdownScript, contentWorld: .world(name: "reader"))
        guard let text = (result as? String)?
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines), text.count > 40 else { return nil }
        return text
    }
}
