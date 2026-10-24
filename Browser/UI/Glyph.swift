import SwiftUI

/// The browser's icons: Phosphor (regular weight; bold where a control needs
/// more presence), as vector template images in the asset catalog, tinted like
/// text. Phosphor Icons is MIT licensed; see README, "Credits".
struct Glyph: View {
    nonisolated enum Kind: String {
        case tabs, plus, chevronUp, back, forward, close, search, pin, history, tab,
             openLink, summarize, browse, share, reload, blocking, settings, copy, popup, equals, link, textSize,
             desktop, reader, translate,
             // Private browsing, as in Arc: an open eye for a normal tab, a closed one for private.
             eye, eyeClosed,
             // Notify Me.
             bell,
             // Cookie pop-ups, in Site Settings.
             cookie,
             // To-do, and Today.
             todo, today, calendar, news
    }

    let kind: Kind
    var size: CGFloat = 20
    var weight: CGFloat = 1.6

    init(_ kind: Kind, size: CGFloat = 20, weight: CGFloat = 1.6) {
        self.kind = kind
        self.size = size
        self.weight = weight
    }

    /// Bold drawings exist for the few glyphs drawn heavier.
    private static let bold: Set<Kind> = [.plus, .chevronUp, .close]

    var body: some View {
        Image("phosphor/\(kind.rawValue)\(weight >= 2 && Self.bold.contains(kind) ? "-bold" : "")")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // The closed eye is drawn low in its 256 grid (99...200, centred
            // on 150, not 128): lift it so it sits centred like every other glyph.
            .offset(y: kind == .eyeClosed ? -size * 22 / 256 : 0)
            .accessibilityHidden(true)
    }
}
