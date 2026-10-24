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
    /// Settings → Show the link you copied: roko reads it to show it, which
    /// iOS asks about unless roko is allowed to paste from other apps.
    static let showKey = "copiedLink.show"

    /// When the clipboard last changed, as far as roko has seen. Kept across
    /// launches, so a link copied yesterday isn't offered as new after a restart.
    private static var seen: (count: Int, at: Date)? = {
        guard let at = defaults.object(forKey: "copiedLink.seenAt") as? Date else { return nil }
        return (defaults.integer(forKey: "copiedLink.seenCount"), at)
    }() {
        didSet {
            defaults.set(seen?.count, forKey: "copiedLink.seenCount")
            defaults.set(seen?.at, forKey: "copiedLink.seenAt")
        }
    }
    private static var taken = defaults.object(forKey: "copiedLink.taken") as? Int ?? -1 {
        didSet { defaults.set(taken, forKey: "copiedLink.taken") }
    }
    private static var offeredAboveBar = defaults.object(forKey: "copiedLink.offered") as? Int ?? -1 {
        didSet { defaults.set(offeredAboveBar, forKey: "copiedLink.offered") }
    }
    private static var defaults: UserDefaults { .standard }
    /// A link roko copied itself: iOS lets an app read its own copy freely.
    private static var ownCopy: (count: Int, url: URL)?
    /// The clipboard as roko left it, going to the background; kept across
    /// launches. A copy is offered only if it changed after that…
    private static var countWhenLeft = defaults.object(forKey: "copiedLink.left") as? Int {
        didSet { defaults.set(countWhenLeft, forKey: "copiedLink.left") }
    }
    /// …and not since roko came back: a link copied in roko (from a page's
    /// menu, the share sheet, anywhere) is never offered back.
    private static var countWhenArrived: Int?

    /// roko is going to the background.
    static func left() {
        countWhenLeft = UIPasteboard.general.changeCount
    }

    /// roko is in front again (or just launched).
    static func arrived() {
        countWhenArrived = UIPasteboard.general.changeCount
    }

    /// Copied elsewhere (another app, a Mac) while roko was away.
    private static var cameFromElsewhere: Bool {
        let count = UIPasteboard.general.changeCount
        return count == (countWhenArrived ?? count) && count != countWhenLeft
    }
    /// What reading the clipboard found, once per copy, so iOS asks at most once.
    private static var peeked: (count: Int, url: URL?)?

    static func isWaiting() async -> Bool {
        let board = UIPasteboard.general
        let count = board.changeCount
        if LaunchClock.isEnabled {
            print("COPIED count=\(count) taken=\(taken) left=\(String(describing: countWhenLeft)) arrived=\(String(describing: countWhenArrived))")
        }
        guard count != taken, cameFromElsewhere else { return false }
        if seen?.count != count { seen = (count, .now) }
        // Recent only: an old link isn't what you came to open.
        guard let seen, Date.now.timeIntervalSince(seen.at) < window else { return false }
        // Throws when the clipboard is empty.
        let found = try? await board.detectedPatterns(for: [\.probableWebURL])
        if LaunchClock.isEnabled { print("COPIED count=\(count) found=\(String(describing: found))") }
        return found?.contains(\.probableWebURL) ?? false
    }

    /// Opening roko with a fresh link: offered above the bar once per copy.
    /// Not one copied in roko, which is already here.
    static func shouldOfferAboveBar() async -> Bool {
        guard await isWaiting() else { return false }
        let count = UIPasteboard.general.changeCount
        guard count != offeredAboveBar, ownCopy?.count != count else { return false }
        offeredAboveBar = count
        return true
    }

    /// After roko copies a link, so the bar can show it as it is.
    static func copiedHere(_ url: URL) {
        ownCopy = (UIPasteboard.general.changeCount, url)
    }

    /// The link itself, when it can be shown: copied in roko, or with
    /// Show the link you copied on.
    static func peek() async -> URL? {
        let count = UIPasteboard.general.changeCount
        if let ownCopy, ownCopy.count == count { return ownCopy.url }
        if let peeked, peeked.count == count { return peeked.url }
        guard UserDefaults.standard.bool(forKey: showKey) else { return nil }
        // Throws when iOS asked and you said no; then the Paste button it is.
        let found = try? await UIPasteboard.general.detectedValues(for: [\.probableWebURL])
        let url = found.flatMap { Omnibox.url(from: $0.probableWebURL) }.flatMap(web)
        peeked = (count, url)
        return url
    }

    /// Opened: not offered again for this copy.
    static func took() {
        taken = UIPasteboard.general.changeCount
    }

    /// The link in what the Paste button handed over.
    static func url(from providers: [NSItemProvider]) async -> URL? {
        took()
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self), let url = await load(URL.self, from: provider).flatMap(web) {
                return url
            }
            if provider.canLoadObject(ofClass: String.self), let text = await load(String.self, from: provider),
               let url = Omnibox.url(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }
        return nil
    }

    private static func web(_ url: URL) -> URL? {
        url.scheme?.hasPrefix("http") == true ? url : nil
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }
}

nonisolated extension URL {
    /// Host and path, without the scheme or "www.": what you'd say the link is.
    var shortDisplay: String {
        let path = path(percentEncoded: false)
        return path.count > 1 ? displayHost + path : displayHost
    }
}

/// The system Paste button, drawn as roko's orange word on the surface it
/// sits on (like "Allow cookies"), not a filled capsule. It pastes without
/// asking: tapping it is the permission.
struct PasteControl: UIViewRepresentable {
    let open: (URL) -> Void

    func makeUIView(context: Context) -> PasteTarget {
        PasteTarget()
    }

    func updateUIView(_ target: PasteTarget, context: Context) {
        target.onPaste = { providers in
            Task { @MainActor in
                if let url = await CopiedLink.url(from: providers) { open(url) }
            }
        }
    }

    /// The space iOS leaves either side of its label; callers pad by that much
    /// less so the word lines up like plain text.
    static let inset: CGFloat = 12

    /// As wide as iOS wants: too narrow for its label ("Paste", or the longer
    /// "Zalijepi" in Croatian) and it draws a blank block instead.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteTarget, context: Context) -> CGSize? {
        CGSize(width: uiView.fittingWidth, height: 44)
    }

    /// Receives the paste. The control itself is drawn by iOS; roko can only
    /// pick its colours, so it's rebuilt when light or dark mode changes.
    final class PasteTarget: UIView {
        var onPaste: (([NSItemProvider]) -> Void)?
        private var control: UIPasteControl?

        init() {
            super.init(frame: .zero)
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.url.identifier,
                                                                                  UTType.plainText.identifier])
            build()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: PasteTarget, _) in self.build() }
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The control reports no size of its own, so measure its word, in
        /// UIKit's own translation, at the size iOS draws it.
        var fittingWidth: CGFloat {
            let word = Bundle(for: UIPasteControl.self).localizedString(forKey: "Paste", value: "Paste", table: nil)
            let width = (word as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .medium)]).width
            return max(64, (width + 2 * PasteControl.inset).rounded(.up))
        }

        private func build() {
            control?.removeFromSuperview()
            var configuration = UIPasteControl.Configuration()
            configuration.displayMode = .labelOnly
            configuration.cornerStyle = .fixed
            configuration.cornerRadius = 10
            // Resolved here: iOS draws the control out of process.
            configuration.baseForegroundColor = UIColor(Theme.accentText).resolvedColor(with: traitCollection)
            configuration.baseBackgroundColor = UIColor(Theme.panel).resolvedColor(with: traitCollection)
            let control = UIPasteControl(configuration: configuration)
            control.target = self
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor),
                control.trailingAnchor.constraint(equalTo: trailingAnchor),
                control.topAnchor.constraint(equalTo: topAnchor),
                control.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.control = control
        }

        override func paste(itemProviders: [NSItemProvider]) {
            onPaste?(itemProviders)
        }
    }
}
