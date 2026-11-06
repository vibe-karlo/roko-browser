import SwiftUI

extension Animation {
    /// The bar opening into the launcher and closing back: a fade and settle in
    /// place, nothing travelling across the screen. It starts gently: an ease-out
    /// flooded the blur in over the first two frames, which read as a pop.
    static let launcher = Animation.timingCurve(0.35, 0, 0.35, 1, duration: 0.26)
    /// The rows arrive once the blur behind them is dense enough to hide the page's
    /// text; any sooner, the list and the headline showed through each other.
    static let launcherRowsIn = Animation.easeOut(duration: 0.14).delay(0.16)
    /// And on the way out they leave before the blur starts to thin.
    static let launcherRowsOut = Animation.easeOut(duration: 0.08)
}

extension AnyTransition {
    /// A screen coming up over the page: a fade, with Reduce Motion on.
    static var rises: AnyTransition { UIAccessibility.isReduceMotionEnabled ? .opacity : .move(edge: .bottom) }

    /// The tab switcher: arrives from below, leaves upward.
    static var switcher: AnyTransition {
        UIAccessibility.isReduceMotionEnabled ? .opacity
            : .asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top).combined(with: .opacity))
    }
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
            .scaleEffect(opened || UIAccessibility.isReduceMotionEnabled ? 1 : 0.98, anchor: .top)
            .offset(y: opened || UIAccessibility.isReduceMotionEnabled ? 0 : -6)
    }
}
