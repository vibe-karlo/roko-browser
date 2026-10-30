import UIKit
import UniformTypeIdentifiers

/// roko in other apps' share sheets: a link opens in roko, text you selected
/// goes to Browse for Me. Nothing to choose, so nothing is shown: it hands
/// what was shared to roko (roko://open, roko://ask) and goes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await hand() }
    }

    private func hand() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        var link: URL?
        var text: String?
        for provider in providers {
            if link == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               url.scheme == "http" || url.scheme == "https" {
                link = url
            } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let shared = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                text = shared.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Text that is just a link (Notes, Messages) opens it too.
        if link == nil, let text, !text.contains(" "), let url = URL(string: text),
           url.scheme == "http" || url.scheme == "https" {
            link = url
        }

        var target = URLComponents()
        target.scheme = "roko"
        if let link {
            target.host = "open"
            target.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        } else if let text, !text.isEmpty {
            target.host = "ask"
            target.queryItems = [URLQueryItem(name: "q", value: String(text.prefix(300)))]
        }
        if target.host != nil, let url = target.url { openRoko(url) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// A share extension has no openURL of its own: the app it runs in does,
    /// found up the responder chain.
    private func openRoko(_ url: URL) {
        var responder: UIResponder? = self
        while let next = responder {
            if let application = next as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = next.next
        }
    }
}
