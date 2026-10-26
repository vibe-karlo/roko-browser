import SwiftUI

extension Animation {
    /// The bar opening into the launcher and closing back: a quick fade and
    /// settle in place, nothing travelling across the screen.
    static let launcher = Animation.easeOut(duration: 0.16)
}

/// The launcher's field appearing where it lives, at the top: it fades in and
/// settles the last few points down into place (and back up on close). It
/// used to fly up from the bar's capsule, which read as the field travelling
/// the length of the screen. `from` is kept for callers; it no longer moves it.
struct LauncherMorph: ViewModifier {
    let from: CGRect
    let to: CGRect
    let opened: Bool

    func body(content: Content) -> some View {
        content
            .opacity(opened ? 1 : 0)
            .scaleEffect(opened ? 1 : 0.98, anchor: .top)
            .offset(y: opened ? 0 : -6)
    }
}
