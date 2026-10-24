import SwiftUI
import UniformTypeIdentifiers

/// A link copied a moment ago: on this iPhone, or on a Mac through Universal
/// Clipboard, the way to carry a page from Chrome on the Mac to roko (iOS
/// hands web pages from a Mac to Safari only). roko only checks whether the
/// clipboard holds a link, which needs no permission; the link itself comes
/// through the system Paste button, which doesn't ask either: tapping it is
/// the permission.
@MainActor
enum CopiedLink {
    /// How long a copied link is offered for.
    static let window: TimeInterval = 5 * 60

    /// When the clipboard last changed, as far as roko has seen.
    private static var seen: (count: Int, at: Date)?
    private static var taken = -1
    private static var offeredAboveBar = -1

    static func isWaiting() async -> Bool {
        let board = UIPasteboard.general
        let count = board.changeCount
        guard count != taken else { return false }
        if seen?.count != count { seen = (count, .now) }
        // Recent only: an old link isn't what you came to open.
        guard let seen, Date.now.timeIntervalSince(seen.at) < window else { return false }
        // Throws when the clipboard is empty.
        let found = try? await board.detectedPatterns(for: [\.probableWebURL])
        return found?.contains(\.probableWebURL) ?? false
    }

    /// Opening roko with a fresh link: offered above the bar once per copy.
    static func shouldOfferAboveBar() async -> Bool {
        guard await isWaiting() else { return false }
        let count = UIPasteboard.general.changeCount
        guard count != offeredAboveBar else { return false }
        offeredAboveBar = count
        return true
    }

    /// The link in what the Paste button handed over.
    static func url(from providers: [NSItemProvider]) async -> URL? {
        taken = UIPasteboard.general.changeCount
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self), let url = await load(URL.self, from: provider),
               url.scheme?.hasPrefix("http") == true {
                return url
            }
            if provider.canLoadObject(ofClass: String.self), let text = await load(String.self, from: provider),
               let url = Omnibox.url(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }
        return nil
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }
}

/// The system Paste button, in roko's accent: it pastes without asking.
struct CopiedLinkButton: View {
    let open: (URL) -> Void

    var body: some View {
        PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
            Task { @MainActor in
                if let url = await CopiedLink.url(from: providers) { open(url) }
            }
        }
        .labelStyle(.titleOnly)
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
    }
}
