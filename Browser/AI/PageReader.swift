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
    /// Words in the text that link somewhere, when that's known. Addresses written out need no entry.
    var links: [PageLink] = []
}

/// Words in a text that link to a page.
nonisolated struct PageLink: Codable, Hashable, Sendable {
    let words: String
    let url: URL
    /// The paragraph they're in, because the same words may be said earlier without
    /// the link. Without one, they go on the first place they're said.
    var block: String? = nil

    /// The links inside an article's paragraphs, as `WebResearcher.articleText` reads them.
    static func inBlocks(of html: String) -> [PageLink] {
        WebResearcher.matches(#"(?i)<(p|li|h[1-3])\b[^>]*>([\s\S]*?)</\1>"#, in: html).flatMap { match in
            match.count == 2 ? anchors(in: match[1], block: WebResearcher.plain(match[1])) : []
        }
    }

    /// Those, and the ones outside any paragraph: a mail's button in a table cell.
    static func anywhere(in html: String) -> [PageLink] {
        let blocks = inBlocks(of: html)
        let placed = Set(blocks.map(\.url))
        return blocks + anchors(in: html, block: nil).filter { !placed.contains($0.url) }
    }

    private static func anchors(in html: String, block: String?) -> [PageLink] {
        WebResearcher.matches(#"(?i)<a\b[^>]*?\bhref\s*=\s*["'](https?://[^"']+)["'][^>]*>(.*?)</a>"#, in: html).compactMap { match in
            guard match.count == 2 else { return nil }
            let words = WebResearcher.plain(match[1])
            guard words.count >= 3, let url = URL(string: WebResearcher.plain(match[0])) else { return nil }
            return PageLink(words: words, url: url, block: block)
        }
    }
}

/// Pulls the article text out of a page with Mozilla's Readability, loaded only
/// when asked for, in its own script world so the page can't interfere.
enum PageReader {
    private static let readability: String = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    // Readability credits a paragraph's nearest ancestors only. Where each section of a
    // story has its own deep wrappers (bbc.co.uk, Ars Technica), one section outscores
    // the story and the rest is lost. So when a page's one <article> says much more than
    // was read, its sections are laid side by side and read again. A wrapper with a
    // button or a form stays shut: that's a paywall's box, not the story.
    private static let parsing = """
    const parsed = (page) => { try { return new Readability(page).parse(); } catch (e) { return null; } };
    const words = (text) => text.replace(/\\s+/g, " ").trim();
    const parseArticle = () => {
      const found = parsed(document.cloneNode(true));
      const copy = document.cloneNode(true);
      const articles = copy.querySelectorAll("article");
      if (articles.length !== 1) return found;
      const story = [...articles[0].querySelectorAll("p")].filter(p => !p.closest("figure,a,li,header,blockquote") && words(p.textContent));
      const held = story.reduce((sum, p) => sum + words(p.textContent).length, 0);
      const read = found ? words(found.textContent).length : 0;
      if (story.length < 3 || read >= held * 0.9) return found;
      let home = story[0].parentElement;
      while (home !== articles[0] && !story.every(p => home.contains(p))) home = home.parentElement;
      const blocks = "p,h2,h3,h4,ul,ol,blockquote";
      for (const section of [...home.children]) {
        if (!/^(DIV|SECTION)$/.test(section.tagName) || !story.some(p => section.contains(p)) || section.querySelector("form,button,input")) continue;
        section.replaceWith(...[...section.querySelectorAll(blocks)].filter(el => !el.parentElement.closest(blocks + ",figure,a,li")));
      }
      copy.body.replaceChildren(home);
      const again = parsed(copy);
      return again && words(again.textContent).length > read ? again : found;
    };
    """

    // Readability's textContent glues adjacent blocks together ("…tontos?Silvia Leal…"),
    // so walk its cleaned HTML and keep each block on its own.
    private static let extract = """
    // What a mail hides isn't for reading: its preview line, a spacer against Gmail's folding.
    if (forMail) for (const el of document.body.querySelectorAll("[style]")) {
      const style = el.getAttribute("style").toLowerCase().replace(/\\s/g, "");
      if (/display:none|visibility:hidden|opacity:0(;|$)|font-size:0(px)?(;|$)|max-height:0(px)?(;|$)/.test(style)
          || (/(^|;)height:[01]px/.test(style) && style.includes("overflow:hidden"))) el.remove();
    }
    // A mail's button is a link alone in a table, which Readability takes for clutter: a line of its own.
    if (forMail) for (const a of [...document.body.querySelectorAll("a[href]")]) {
      const words = a.textContent.trim();
      if (!words) continue;
      let alone = a;
      while (alone.parentElement !== document.body && alone.parentElement.textContent.trim() === words) alone = alone.parentElement;
      if (alone === a) continue;
      const line = document.createElement("p");
      line.append(a.cloneNode(true));
      alone.replaceWith(line);
    }
    const article = forMail ? parsed(document.cloneNode(true)) : parseArticle();
    const blocks = [], links = [];
    if (article && article.content) {
      const doc = new DOMParser().parseFromString(article.content, "text/html");
      // A line break is a space between words.
      for (const br of doc.body.querySelectorAll("br")) br.replaceWith(" ");
      const selector = "h1,h2,h3,h4,p,li,blockquote,pre,figcaption";
      for (const el of doc.body.querySelectorAll(selector)) {
        if (el.parentElement && el.parentElement.closest(selector)) continue;
        const text = el.textContent.replace(/\\s+/g, " ").trim();
        if (!text) continue;
        blocks.push(text);
        for (const a of el.querySelectorAll("a[href]")) {
          const words = a.textContent.replace(/\\s+/g, " ").trim();
          let url;
          try { url = new URL(a.getAttribute("href"), location.href); } catch (e) { continue; }
          // A footnote's jump down this same page is no use without the page.
          if (words.length < 3 || !/^https?:$/.test(url.protocol) || (url.hash && url.href.split("#")[0] === location.href.split("#")[0])) continue;
          links.push({ words: words, url: url.href, block: text });
        }
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
      links: links.slice(0, 500),
      lang: document.documentElement.lang || ""
    };
    """

    static func read(_ webView: WKWebView, forMail: Bool = false) async throws -> ReadablePage {
        let result = try await webView.callAsyncJavaScript(
            readability + "\n" + parsing + "\n" + extract, arguments: ["forMail": forMail], contentWorld: .world(name: "reader"))
        guard let fields = result as? [String: Any] else {
            throw ClaudeError(message: "This page has no readable text.")
        }
        let text = withoutFurniture((fields["text"] as? String ?? "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines), forMail: forMail)
        guard text.count > 200 else { throw ClaudeError(message: "This page has too little text to summarize.") }
        return ReadablePage(title: fields["title"] as? String ?? "", site: fields["site"] as? String ?? "",
                            text: String(text.prefix(200_000)), isArticle: fields["isArticle"] as? Bool ?? false,
                            declaredLanguage: (fields["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            links: (fields["links"] as? [[String: String]] ?? []).compactMap { link in
                                guard let words = link["words"], let url = link["url"].flatMap(URL.init(string:)) else { return nil }
                                return PageLink(words: words, url: url, block: link["block"])
                            })
    }

    /// What Readability takes for paragraphs and isn't. Anywhere: "Advertisement",
    /// the NYT's note about checking your access, a photo's credit. Above the
    /// first real paragraph, short lines that aren't sentences: "44 minutes
    /// ago", "Daniela RelphRoyal correspondent", "Reuters". What the BBC writes
    /// for screen readers goes too: "Image source, Getty", and a caption's label.
    /// A mail's opening stays: a short line there may be what it's for, like a sign-in code.
    nonisolated static func withoutFurniture(_ text: String, forMail: Bool = false) -> String {
        let furniture: Set<String> = ["advertisement", "skip advertisement", "reklama", "oglas", "continue reading", "read more",
                                      "pročitajte više", "share", "save", "podijeli"]
        var lines = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).replacing(#/^(Image|Figure|Media) caption, /#, with: "")
        }.filter { line in
            let plain = line.lowercased()
            guard !line.isEmpty, !furniture.contains(plain), !plain.hasPrefix("you have a preview view of this article"), !plain.hasPrefix("image source, ") else { return false }
            // A newsletter's small print: Reader has its own way to leave the list.
            if plain.count < 200, plain.contains("unsubscribe") || plain.contains("odjavi") { return false }
            return plain.count > 40 || plain.firstMatch(of: /\b(getty images|reuters|afp|associated press|pa media|epa|shutterstock|alamy|pixsell|hina)\b/) == nil
        }
        if forMail {
            // Invisible padding after a preview line, and that preview line said again.
            var seen = Set<String>()
            lines = lines.filter { line in
                line.contains { $0.isLetter || $0.isNumber } && (line.count < 20 || seen.insert(line).inserted)
            }
        } else if let first = lines.prefix(8).firstIndex(where: { $0.count >= 80 }) {
            let kept = lines[..<first].filter { $0.count >= 60 || $0.last.map { ".?!:".contains($0) } == true }
            lines = Array(kept) + lines[first...]
        }
        return lines.joined(separator: "\n\n")
    }

    /// The article as Markdown, for notes or an AI chat: its title, headings,
    /// paragraphs, lists, quotes, code and links, without the page around it.
    /// The whole page's text when it has no article.
    private static let markdownScript = """
    const article = parseArticle();
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
            readability + "\n" + parsing + "\n" + markdownScript, contentWorld: .world(name: "reader"))
        guard let text = (result as? String)?
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines), text.count > 40 else { return nil }
        return text
    }
}
