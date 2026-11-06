import Foundation
import WebKit

/// Newsletters in News: a private address to subscribe with or forward to. Mail
/// sent there waits on roko's server (`Server/share/src/inbox.js`) until it's
/// fetched here, then it's deleted there. Each one becomes a story with a
/// "roko-mail:" address, its text for Reader, its original kept beside it.
enum Newsletters {
    private static let addressKey = "newsletters.address"
    private static let folder = URL.applicationSupportDirectory.appending(path: "newsletters")

    static var isOffered: Bool { AnswerSharing.server != nil }
    static var isOn: Bool { Keychain.inboxKey != nil }
    static var address: String? { UserDefaults.standard.string(forKey: addressKey) }

    private nonisolated struct Opened: Decodable {
        let address: String
        let key: String
    }

    private nonisolated struct Waiting: Decodable {
        let mail: [Mail]
    }

    private nonisolated struct Mail: Decodable, Sendable {
        let id: String
        let sender: String
        let sender_name: String?
        let subject: String
        let received: Double
        let unsubscribe: String?
        let html: String?
        let text: String?
    }

    /// Opens a box, and says why not if it can't.
    static func open() async -> String? {
        guard let server = AnswerSharing.server else { return "Newsletters aren't available in this build." }
        var request = URLRequest(url: server.appending(path: "api/inbox"), timeoutInterval: 15)
        request.httpMethod = "POST"
        guard let (data, response) = try? await URLSession.quick.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 201,
              let opened = try? JSONDecoder().decode(Opened.self, from: data) else {
            return "Couldn't make an address just now. Try again in a moment."
        }
        Keychain.inboxKey = opened.key
        UserDefaults.standard.set(opened.address, forKey: addressKey)
        return nil
    }

    /// Ends the address, and whatever's waiting at it. What's arrived stays here.
    static func close() async {
        if let server = AnswerSharing.server, let key = Keychain.inboxKey {
            var request = URLRequest(url: server.appending(path: "api/inbox"), timeoutInterval: 15)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.quick.data(for: request)
        }
        Keychain.inboxKey = nil
        UserDefaults.standard.removeObject(forKey: addressKey)
    }

    /// What's arrived since last time, as stories. Off the server only once they're
    /// saved (`forgetKept`): until then a closed app would have lost them.
    /// With roko closed there's no web view to read a mail with: its plain text it is.
    static func fetch(inBackground: Bool) async -> [NewsStory] {
        guard let server = AnswerSharing.server, let key = Keychain.inboxKey else { return [] }
        var request = URLRequest(url: server.appending(path: "api/inbox"), timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.quick.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let waiting = try? JSONDecoder().decode(Waiting.self, from: data) else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stories: [NewsStory] = []
        for mail in waiting.mail {
            guard let link = URL(string: "roko-mail://mail/\(mail.id)") else { continue }
            let original = mail.html ?? "<pre style=\"white-space:pre-wrap;font:17px -apple-system\">\(escaped(mail.text ?? ""))</pre>"
            guard (try? original.write(to: file(for: link), atomically: true, encoding: .utf8)) != nil else { continue }
            var text = mail.text ?? ""
            if text.isEmpty, let html = mail.html { text = plainText(html) }
            // The sender's own plain version keeps headings and lines Readability drops
            // from a table of a mail. Readability's for when that's thin or mostly addresses.
            if !inBackground, !isGoodPlainText(text), let html = mail.html,
               let read = await RenderedPage.readable(html: html), read.text.count > text.count / 2 {
                text = read.text
            }
            var story = NewsStory(title: mail.subject, link: link, host: domain(of: mail.sender),
                                  published: Date(timeIntervalSince1970: mail.received / 1000))
            story.from = mail.sender_name ?? mail.sender
            story.unsubscribe = mail.unsubscribe.flatMap(URL.init(string:))
            story.content = PageReader.withoutFurniture(text, forMail: true)
            stories.append(story)
            kept.append(mail.id)
        }
        return stories
    }

    /// Fetched but still only in memory: on the server until `forgetKept`.
    private static var kept: [String] = []

    /// Off the server, now they're saved here. Had roko been closed before this,
    /// they'd have been fetched again next time and landed on the same stories.
    static func forgetKept() async {
        guard let server = AnswerSharing.server, let key = Keychain.inboxKey else { return }
        let ids = kept
        kept = []
        for id in ids {
            var done = URLRequest(url: server.appending(path: "api/inbox/\(id)"), timeoutInterval: 15)
            done.httpMethod = "DELETE"
            done.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.quick.data(for: done)
        }
    }

    static func original(of link: URL) -> String? {
        try? String(contentsOf: file(for: link), encoding: .utf8)
    }

    /// The words in a mail that link to a page, from its original. Its text may be
    /// the plain version, whose paragraphs differ: there, they go wherever they're said.
    static func links(of link: URL, in text: String) -> [PageLink] {
        guard let html = original(of: link) else { return [] }
        let paragraphs = Set(text.components(separatedBy: "\n"))
        return PageLink.anywhere(in: html).map { link in
            link.block.map(paragraphs.contains) == true ? link : PageLink(words: link.words, url: link.url)
        }
    }

    static func forget(_ link: URL) {
        try? FileManager.default.removeItem(at: file(for: link))
    }

    private static func file(for link: URL) -> URL {
        folder.appending(path: link.lastPathComponent + ".html")
    }

    private static func isGoodPlainText(_ text: String) -> Bool {
        let addresses = text.matches(of: /https?:\/\/\S+/).map(\.0.count).reduce(0, +)
        return text.count >= 200 && Double(addresses) / Double(text.count) < 0.15
    }

    /// An HTML-only mail's words, for one too short for Readability or read with roko closed.
    private static func plainText(_ html: String) -> String {
        var body = html
        for tag in ["head", "style", "script"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return body.replacingOccurrences(of: "(?i)</(p|div|tr|li|h[1-6])>|<br[^>]*>", with: "\n", options: .regularExpression)
            .components(separatedBy: "\n").map(WebResearcher.plain).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func domain(of sender: String) -> String {
        let domain = sender.split(separator: "@").last.map { String($0).lowercased() } ?? sender
        return domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
