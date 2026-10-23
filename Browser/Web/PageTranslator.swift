import Foundation
import NaturalLanguage
import Translation
import WebKit

/// The languages the page menu offers to translate into.
enum TranslationTarget: String, CaseIterable, Identifiable {
    case english = "en", croatian = "hr"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .english: "English"
        case .croatian: "Hrvatski"
        }
    }
}

/// Translates a page in place: the text on it is swapped for its translation,
/// so the layout, your logins and the blocker all stay as they were (unlike
/// opening the page through a translation proxy). Text on screen goes first;
/// text that appears later (infinite scroll, opened menus) follows.
///
/// Engine: Apple's on-device translation when it can (into English, from a
/// language already downloaded on the phone: private, no network). Otherwise
/// Google Translate's web endpoint, which also covers Croatian; Apple's doesn't.
@MainActor
final class PageTranslator: NSObject, WKScriptMessageHandler {
    static let shared = PageTranslator()
    static let world = WKContentWorld.world(name: "translate")

    /// Tabs being translated, so new text on them is translated too.
    private var targets: [ObjectIdentifier: TranslationTarget] = [:]

    func translate(_ webView: WKWebView, to target: TranslationTarget) async {
        targets[ObjectIdentifier(webView)] = target
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "translate", contentWorld: Self.world)
        controller.add(self, contentWorld: Self.world, name: "translate")
        await translatePending(in: webView, to: target)
    }

    func restore(_ webView: WKWebView) async {
        targets[ObjectIdentifier(webView)] = nil
        _ = try? await webView.callAsyncJavaScript(Self.restoreScript, contentWorld: Self.world)
    }

    /// The page script reports new text a moment after it appears.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let target = targets[ObjectIdentifier(webView)] else { return }
        Task { await translatePending(in: webView, to: target) }
    }

    // MARK: Collect, translate, apply

    private func translatePending(in webView: WKWebView, to target: TranslationTarget) async {
        guard let result = try? await webView.callAsyncJavaScript(Self.collectScript, contentWorld: Self.world),
              let page = result as? [String: Any],
              let start = page["start"] as? Int, let texts = page["texts"] as? [String], !texts.isEmpty else { return }
        let declared = page["lang"] as? String ?? ""

        // Menus and buttons repeat; each distinct string is translated once.
        var unique: [String] = []
        var position: [String: Int] = [:]
        for text in texts where position[text] == nil {
            position[text] = unique.count
            unique.append(text)
        }

        // Chunks in reading order, applied as each arrives, so the screen
        // you're looking at changes first.
        let chunks = Self.chunks(of: unique)
        var translated = [String?](repeating: nil, count: unique.count)
        let source = Self.language(declared: declared, sample: unique)
        await withTaskGroup(of: (Int, [String]?).self) { group in
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let index = next
                next += 1
                let range = chunks[index]
                let slice = Array(unique[range])
                group.addTask { (index, try? await Self.engineTranslate(slice, to: target, source: source)) }
            }
            for _ in 0..<min(4, chunks.count) { addNext() }
            for await (index, result) in group {
                if let result {
                    let range = chunks[index]
                    for (offset, text) in result.enumerated() where range.lowerBound + offset < translated.count {
                        translated[range.lowerBound + offset] = text
                    }
                    // Hand the page every node whose text is now known.
                    let mapped = texts.map { position[$0].flatMap { translated[$0] } ?? NSNull() as Any }
                    _ = try? await webView.callAsyncJavaScript(
                        "window.__rokoTranslate && window.__rokoTranslate.apply(start, texts)",
                        arguments: ["start": start, "texts": mapped], contentWorld: Self.world)
                }
                addNext()
            }
        }
    }

    /// Up to 100 strings or about 4,000 characters each.
    private static func chunks(of texts: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var begin = 0, characters = 0
        for (index, text) in texts.enumerated() {
            if index > begin, index - begin >= 100 || characters + text.count > 4000 {
                ranges.append(begin..<index)
                begin = index
                characters = 0
            }
            characters += text.count
        }
        if begin < texts.count { ranges.append(begin..<texts.count) }
        return ranges
    }

    private static func language(declared: String, sample: [String]) -> Locale.Language? {
        if let code = declared.split(separator: "-").first, code.count == 2 {
            return Locale.Language(identifier: String(code))
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample.prefix(40).joined(separator: " "))
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    // MARK: Engines

    private nonisolated static func engineTranslate(_ texts: [String], to target: TranslationTarget,
                                                    source: Locale.Language?) async throws -> [String] {
        if let source, source.minimalIdentifier != target.rawValue,
           await LanguageAvailability().status(from: source, to: Locale.Language(identifier: target.rawValue)) == .installed {
            let session = TranslationSession(installedSource: source, target: Locale.Language(identifier: target.rawValue))
            if let responses = try? await session.translations(from: texts.map { .init(sourceText: $0) }),
               responses.count == texts.count {
                return responses.map(\.targetText)
            }
        }
        return try await google(texts, to: target.rawValue)
    }

    /// Google Translate's free web endpoint, as its own page widget uses it.
    private nonisolated static func google(_ texts: [String], to target: String) async throws -> [String] {
        var request = URLRequest(url: URL(string:
            "https://translate.googleapis.com/translate_a/t?client=gtx&sl=auto&tl=\(target)&dt=t&format=text")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        request.httpBody = texts
            .map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw URLError(.badServerResponse) }
        // One [translation, detectedLanguage] pair per input, in order.
        let results = json.map { item -> String? in
            if let pair = item as? [Any] { return pair.first as? String }
            return item as? String
        }
        guard results.count == texts.count else { throw URLError(.cannotParseResponse) }
        return zip(results, texts).map { $0 ?? $1 }
    }

    // MARK: Page scripts (isolated world: the page can't see or tamper with them)

    /// Gathers text not yet seen, on-screen first. Returns where it starts in the
    /// page's list, the strings, and the page's declared language.
    private static let collectScript = """
        const state = window.__rokoTranslate || (window.__rokoTranslate = {
          nodes: [], originals: [], seen: new WeakSet(), observer: null, timer: 0,
          apply(start, texts) {
            texts.forEach((text, i) => {
              const node = this.nodes[start + i], original = this.originals[start + i];
              if (!node || text == null) return;
              // Keep the spacing around the words, so inline text doesn't run together.
              node.nodeValue = original.match(/^\\s*/)[0] + text + original.match(/\\s*$/)[0];
            });
          },
        });
        const skip = "script,style,noscript,code,pre,kbd,samp,textarea,svg,math,[translate=no],.notranslate,[contenteditable=true]";
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            if (state.seen.has(node) || !/\\p{L}/u.test(node.nodeValue)) return NodeFilter.FILTER_REJECT;
            const parent = node.parentElement;
            return !parent || parent.closest(skip) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          },
        });
        const fresh = [];
        for (let node; (node = walker.nextNode());) { state.seen.add(node); fresh.push(node); }
        // On screen first, then below, then above.
        const rank = (node) => {
          const box = node.parentElement.getBoundingClientRect();
          if (box.bottom >= 0 && box.top <= innerHeight) return box.top;
          return box.top > innerHeight ? 100000 + box.top : 1000000 - box.bottom;
        };
        const ranked = fresh.map((node) => [rank(node), node]).sort((a, b) => a[0] - b[0]).map((pair) => pair[1]);
        const start = state.nodes.length;
        for (const node of ranked) { state.nodes.push(node); state.originals.push(node.nodeValue); }
        // New text later (infinite scroll, opened menus): tell the app, at most every 800 ms.
        if (!state.observer) {
          state.observer = new MutationObserver(() => {
            if (state.timer) return;
            state.timer = setTimeout(() => { state.timer = 0; window.webkit.messageHandlers.translate.postMessage("more"); }, 800);
          });
          state.observer.observe(document.body, { childList: true, subtree: true });
        }
        return { start, texts: ranked.map((node) => node.nodeValue.trim()), lang: document.documentElement.lang || "" };
        """

    private static let restoreScript = """
        const state = window.__rokoTranslate;
        if (!state) return;
        if (state.observer) state.observer.disconnect();
        state.nodes.forEach((node, i) => { node.nodeValue = state.originals[i]; });
        delete window.__rokoTranslate;
        """
}
