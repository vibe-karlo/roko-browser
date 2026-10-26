import SwiftUI

extension Animation {
    /// The bar opening into the launcher and closing back into it.
    /// Quick enough to read as the bar simply becoming the launcher.
    static let launcher = Animation.spring(duration: 0.11, bounce: 0)
}

/// The launcher's field, drawn first exactly over the bar capsule that was
/// tapped (`from`, on screen), then grown into its own place (`to`): one
/// shape widening and rising out of the bar, and shrinking back into it on
/// close. Its frame grows, not its scale: what's in it stays its own size,
/// clipped by the growing shape, so the field is never an empty pill in
/// flight (scaled, its contents had to be hidden until it landed).
struct LauncherMorph: ViewModifier {
    let from: CGRect
    let to: CGRect
    let opened: Bool

    func body(content: Content) -> some View {
        let ready = from != .zero && to != .zero
        let small = !opened && ready
        content
            .frame(width: small ? from.width : nil, height: small ? from.height : nil, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: opened ? 18 : 28))
            .frame(maxWidth: .infinity)
            .offset(x: small ? from.midX - to.midX : 0, y: small ? from.midY - to.midY : 0)
    }
}
