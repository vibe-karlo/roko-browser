import Foundation
import UIKit

/// Browse for Me pages shared from earlier betas, which stay on roko's server
/// (Server/share) until they're taken down here. Answers can't be shared any more.
@MainActor
enum AnswerSharing {
    /// The server, from the SHARE_SERVER build setting, which Mac sync uses too.
    /// A debug build takes `-shareServer http://127.0.0.1:8787` too.
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

    private static func request(_ url: URL, method: String, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return request
    }

    private static func error(from data: Data, status: Int) -> ShareError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        return ShareError(message: message ?? "Couldn't unshare it (error \(status)). Try again in a moment.")
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
