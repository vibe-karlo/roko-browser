import SwiftUI

extension Animation {
    /// The bar opening into the launcher and closing back into it.
    static let launcher = Animation.spring(duration: 0.2, bounce: 0.04)
}

/// The launcher's field, drawn first exactly over the bar capsule that was
/// tapped (`from`, on screen), then grown into its own place (`to`): one
/// shape widening and rising out of the bar, and shrinking back into it on
/// close. Scaled and moved, not laid out again, so nothing reflows mid-way.
struct LauncherMorph: ViewModifier {
    let from: CGRect
    let to: CGRect
    let opened: Bool

    func body(content: Content) -> some View {
        let ready = from != .zero && to != .zero
        content
            .scaleEffect(x: opened || !ready ? 1 : from.width / to.width,
                         y: opened || !ready ? 1 : from.height / to.height)
            .offset(x: opened || !ready ? 0 : from.midX - to.midX,
                    y: opened || !ready ? 0 : from.midY - to.midY)
    }
}
