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
    /// A small control of the screen's own in the right-hand place (Browse for
    /// Me's AI and search switch), instead of `trailing`. Both sides then take
    /// its width, so the middle stays in the middle.
    var accessory: AnyView? = nil
    var accessoryWidth: CGFloat = 64
    /// The title when the whole one doesn't fit beside the accessory.
    var shortTitle: String? = nil
    @Environment(BrowserModel.self) private var browser
    @State private var capsuleFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 0) {
            place(leading)
                .frame(width: accessory == nil ? nil : accessoryWidth + 13, alignment: .leading)
            Spacer(minLength: 8)
            Button {
                browser.launcherOrigin = capsuleFrame
                launch()
            } label: {
                HStack(spacing: 8) {
                    Glyph(glyph, size: 17, weight: 1.8)
                    // Whole or shorter, never cut off: "Ask a follow-up" or "Follow up".
                    ViewThatFits(in: .horizontal) {
                        Text(title)
                        if let short = shortTitle { Text(short) }
                    }
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                }
                .padding(.horizontal, 18)
                .frame(minWidth: 104)
                .frame(height: 38)
                .background {
                    if !(morphs && browser.panel == .command) {
                        if let fieldSpace {
                            Capsule().fill(Theme.raised).matchedGeometryEffect(id: "field", in: fieldSpace)
                        } else {
                            Capsule().fill(Theme.raised)
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { capsuleFrame = $0 }
                .contentShape(.capsule)
            }
            .buttonStyle(GlyphButtonStyle())
            Spacer(minLength: 8)
            if let accessory {
                // 13 points from the edge, as the close button's circle is on the left.
                accessory
                    .frame(width: accessoryWidth, alignment: .trailing)
                    .padding(.trailing, 13)
            } else {
                place(trailing)
            }
        }
        .frame(height: Theme.barHeight + 8)
        .barSurface(cornerRadius: Theme.barRadius)
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
