import SwiftUI

/// The one bar, everywhere: the browser's bottom bar, shaped for the screen
/// it's on. Same surface, height and three places (a round button, the wide
/// launcher in the middle, a round button); what they do is the screen's own:
/// a page's tabs and menu, To-do's "New to-do", an answer's follow-up.
/// The middle always opens the launcher, set up for that screen.
struct ContextBar: View {
    struct Slot {
        let glyph: Glyph.Kind
        let label: String
        let action: () -> Void
    }

    let leading: Slot?
    let glyph: Glyph.Kind
    let title: String
    let launch: () -> Void
    var trailing: Slot? = nil
    /// Off where the screen draws its own edge above the bar.
    var fades = true
    /// The launcher opens out of this bar's capsule (not To-do's, which types in place).
    var morphs = true
    /// Where the capsule widens into a field of the screen's own (To-do's), if any.
    var fieldSpace: Namespace.ID? = nil
    @Environment(BrowserModel.self) private var browser
    @Environment(\.launcherSpace) private var launcherSpace

    var body: some View {
        HStack(spacing: 0) {
            place(leading)
            Spacer(minLength: 8)
            Button(action: launch) {
                HStack(spacing: 8) {
                    Glyph(glyph, size: 17, weight: 1.8)
                    Text(title).font(.system(size: 16, weight: .medium))
                }
                .padding(.horizontal, 20)
                .frame(minWidth: 104)
                .frame(height: 38)
                .background {
                    if !(morphs && browser.panel == .command) {
                        Capsule().fill(Theme.raised)
                            .overlay(Capsule().strokeBorder(Theme.edge))
                            .launcherMorph(fieldSpace ?? (morphs ? launcherSpace : nil), id: fieldSpace == nil ? "launcher" : "field")
                    }
                }
                .contentShape(.capsule)
            }
            .buttonStyle(GlyphButtonStyle())
            Spacer(minLength: 8)
            place(trailing)
        }
        .frame(height: Theme.barHeight + 8)
        .barSurface(cornerRadius: 24)
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 4)
        // What scrolls under the bar dissolves above it rather than being sliced by its edge.
        .background(alignment: .top) { if fades { FadeEdge(color: Theme.canvas, height: 40).offset(y: 12) } }
    }

    /// A round button as the page bar's ⌃ is, or the same space kept empty,
    /// so the middle stays in the middle.
    @ViewBuilder
    private func place(_ slot: Slot?) -> some View {
        if let slot {
            Button(action: slot.action) {
                Glyph(slot.glyph, size: 16, weight: 2)
                    .frame(width: 38, height: 38)
                    .background(Theme.raised, in: .circle)
                    .overlay(Circle().strokeBorder(Theme.edge))
                    .frame(width: 64, height: Theme.barHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel(slot.label)
        } else {
            Color.clear.frame(width: 64, height: Theme.barHeight)
        }
    }
}
