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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var capsuleFrame: CGRect = .zero

    private var capsule: some View { Capsule().fill(.white.opacity(0.14)) }

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
                            capsule.matchedGeometryEffect(id: "field", in: fieldSpace)
                        } else {
                            capsule
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
        .frame(height: Theme.barHeight)
        // On a wide screen, a bar's width, where a page's bar is: open, in the middle of the
        // screen whichever side the clock is, or on one half if bent; shut, clear of the camera.
        .frame(maxWidth: verticalSizeClass == .compact || browser.uprightFoldOpen ? 480 : nil)
        .keepsOffFold()
        .ignoresSafeArea(.container, edges: browser.uprightFoldOpen ? .horizontal : [])
        .modifier(ScreenBarSurface())
    }

    /// A round button as the page bar's ⌃ is, or the same space kept empty,
    /// so the middle stays in the middle.
    @ViewBuilder
    private func place(_ slot: Slot?) -> some View {
        if let slot {
            Button(action: slot.action) {
                Glyph(slot.glyph, size: 16, weight: 2)
                    .frame(width: 38, height: 38)
                    .frame(width: 64, height: Theme.barHeight)
                    .contentShape(.rect)
                    // Its ends on the same line as a page's bar.
                    .padding(.horizontal, 6)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel(slot.label)
        } else {
            Color.clear.frame(width: 76, height: Theme.barHeight)
        }
    }
}

/// The band: the same place on screen as a page's bar, down into the home
/// indicator's strip, on the band's graphite.
private struct ScreenBarSurface: ViewModifier {
    @State private var bottomInset: CGFloat = 34

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.ink)
            .environment(\.colorScheme, .dark)
            .padding(.top, 5)
            .background(alignment: .top) {
                LinearGradient(colors: [Color(uiColor: UIColor(hex: 0x131211)), Color(uiColor: UIColor(hex: 0x201E1C))],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(BandFloor())
                    .padding(.top, -BandFloor.lip)
                    .ignoresSafeArea(edges: [.bottom, .horizontal])
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
            // As far into the strip as a page's bar goes, on whatever the strip's depth is.
            .padding(.bottom, max(bottomInset - 20, 9) - bottomInset)
    }
}
