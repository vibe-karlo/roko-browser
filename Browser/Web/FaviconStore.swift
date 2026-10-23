import UIKit
import WebKit

/// Site icons, read from the page itself rather than a third-party icon
/// service, so no browsing history leaks to anyone. Cached on disk by host.
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    private(set) var icons: [String: UIImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func icon(for host: String) -> UIImage? {
        if let icon = icons[host] { return icon }
        let file = directory.appendingPathComponent(host)
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        icons[host] = image
        return image
    }

    func refresh(from webView: WKWebView) async {
        guard let host = webView.url?.displayHost, icon(for: host) == nil, !inFlight.contains(host) else { return }
        inFlight.insert(host)
        defer { inFlight.remove(host) }

        let script = """
        const links = [...document.querySelectorAll("link[rel~='icon'], link[rel='apple-touch-icon']")];
        const best = links.find(l => l.rel.includes('apple-touch-icon')) || links[0];
        return best ? best.href : new URL('/favicon.ico', location.href).href;
        """
        guard let href = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? String,
              let url = URL(string: href),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }

        icons[host] = image
        try? data.write(to: directory.appendingPathComponent(host))
    }
}
