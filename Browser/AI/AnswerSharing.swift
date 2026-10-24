import CryptoKit
import Foundation
import UIKit

/// Browse for Me pages as links anyone can open: on Share, the page goes to
/// roko's share server (Server/share), which answers with a short link. Nothing
/// leaves the iPhone until you tap Share. Sharing again after a follow-up
/// updates the same page, so a link already sent shows the whole page.
@MainActor
enum AnswerSharing {
    /// The server, from the SHARE_SERVER build setting; none, and Share isn't
    /// offered. A debug build takes `-shareServer http://127.0.0.1:8787` too.
    static let server: URL? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-shareServer"), index + 1 < arguments.count {
            return URL(string: arguments[index + 1])
        }
        #endif
        let setting = Bundle.main.object(forInfoDictionaryKey: "RokoShareServer") as? String ?? ""
        return setting.isEmpty ? nil : URL(string: setting)
    }()

    static var isAvailable: Bool { server != nil }

    /// A page shared from this iPhone. The token is what lets this iPhone, and
    /// only it, update or unshare the page.
    struct Shared: Codable, Identifiable, Equatable {
        let id: String
        let url: URL
        let token: String
        var title: String
        var date: Date
        /// What was last sent, so sharing an unchanged page sends nothing.
        var fingerprint: String
    }

    struct ShareError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Pages shared from here

    private static let key = "sharedAnswers"

    /// Newest first, for Settings.
    static var all: [Shared] {
        get {
            (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Shared].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    private static func remember(_ shared: Shared) {
        all = [shared] + all.filter { $0.id != shared.id }
    }

    // MARK: Sharing

    /// The page's link: made the first time, updated after that.
    static func share(_ session: BrowseSession) async throws -> URL {
        guard let server else { throw ShareError(message: "Sharing isn't set up in this build.") }
        let payload = try payload(for: session)
        let fingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let title = session.turns.first?.query ?? ""

        if let shared = session.shared {
            if shared.fingerprint == fingerprint { return shared.url }
            var request = request(server.appending(path: "api/share/\(shared.id)"), method: "PUT", token: shared.token)
            request.httpBody = payload
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                var updated = shared
                updated.fingerprint = fingerprint
                updated.date = .now
                session.shared = updated
                remember(updated)
                return updated.url
            }
            // Unshared meanwhile (from Settings): a new link instead.
            guard status == 404 else { throw error(from: data, status: status) }
        }

        var request = request(server.appending(path: "api/share"), method: "POST")
        request.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201, let created = try? JSONDecoder().decode(Created.self, from: data),
              let url = URL(string: created.url) else { throw error(from: data, status: status) }
        let shared = Shared(id: created.id, url: url, token: created.token, title: title, date: .now, fingerprint: fingerprint)
        session.shared = shared
        remember(shared)
        return url
    }

    /// Takes the page down: its link stops working everywhere.
    static func unshare(_ shared: Shared) async throws {
        all = all.filter { $0.id != shared.id }
        guard let server else { return }
        let (data, response) = try await URLSession.shared.data(
            for: request(server.appending(path: "api/share/\(shared.id)"), method: "DELETE", token: shared.token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Already gone counts as done.
        guard status == 204 || status == 404 else {
            all = [shared] + all
            throw error(from: data, status: status)
        }
    }

    // MARK: Wire format

    private struct Created: Decodable {
        let id: String
        let url: String
        let token: String
    }

    private struct Payload: Encodable {
        struct Turn: Encodable {
            let question: String
            let answer: String
            let sources: [Source]
            let images: [String]
        }
        struct Source: Encodable {
            let url: String
            let title: String
        }
        let lang: String
        let turns: [Turn]
    }

    /// The finished questions and answers, as the page shows them.
    private static func payload(for session: BrowseSession) throws -> Data {
        let turns = session.turns.filter { $0.phase == .done }.map { turn in
            Payload.Turn(question: turn.query, answer: turn.answer,
                         sources: turn.sources.map { Payload.Source(url: $0.url.absoluteString, title: $0.title) },
                         // https only: a plain-http picture can't show on an https page.
                         images: turn.images.filter { $0.scheme == "https" }.map(\.absoluteString))
        }
        guard !turns.isEmpty else { throw ShareError(message: "There's no answer to share yet.") }
        let language = AnswerLanguage.target(for: turns.map(\.question).joined(separator: "\n"))
        return try JSONEncoder().encode(Payload(lang: language?.code ?? "", turns: turns))
    }

    private static func request(_ url: URL, method: String, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return request
    }

    private static func error(from data: Data, status: Int) -> ShareError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        return ShareError(message: message ?? "Couldn't share it (error \(status)). Try again in a moment.")
    }
}

/// The system share sheet, over whatever is on screen.
@MainActor
enum ShareSheet {
    static func present(_ items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?
            .rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad: from the middle of the screen.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(sheet, animated: true)
    }
}
