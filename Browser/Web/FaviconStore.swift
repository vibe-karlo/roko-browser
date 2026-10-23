import UIKit
import WebKit

/// Site icons, read from the page itself rather than a third-party icon
/// service, so no browsing history leaks to anyone. Cached on disk by host.
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    /// Bumped when a new icon arrives, so views showing that site redraw.
    /// Reading an icon never changes observed state (that would be a state
    /// change during drawing, which SwiftUI can loop on).
    private(set) var version = 0
    @ObservationIgnored private let memory = NSCache<NSString, UIImage>()
    /// Hosts with no icon on disk, so a redraw doesn't look again.
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func icon(for host: String) -> UIImage? {
        _ = version  // redraw when icons arrive
        if let icon = memory.object(forKey: host as NSString) { return icon }
        guard !missing.contains(host) else { return nil }
        let file = directory.appendingPathComponent(host)
        // Small files (a few KB); read once per host, then served from memory.
        // The site's own icon first; for well-known sites never visited, the
        // one bundled with the app (Scripts/fetch_site_icons.py).
        guard let image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) ?? Self.bundled(host) else {
            missing.insert(host)
            return nil
        }
        memory.setObject(image, forKey: host as NSString)
        return image
    }

    /// "web.whatsapp.com" falls back to whatsapp.com's mark.
    private static func bundled(_ host: String) -> UIImage? {
        if let image = UIImage(named: "site/\(host)") { return image }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return nil }
        return UIImage(named: "site/\(labels.dropFirst().joined(separator: "."))")
    }

    /// Under memory pressure: drop the decoded icons; they reload from disk.
    func trimMemory() {
        memory.removeAllObjects()
    }

    func refresh(from webView: WKWebView) async {
        // A bundled icon doesn't count: the site's own (often sharper) one still replaces it.
        guard let host = webView.url?.displayHost, !inFlight.contains(host),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent(host).path) else { return }
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

        memory.setObject(image, forKey: host as NSString)
        missing.remove(host)
        version += 1
        let file = directory.appendingPathComponent(host)
        Task.detached(priority: .utility) { try? data.write(to: file) }
    }
}
