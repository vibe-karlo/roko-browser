import SwiftUI
import UIKit

/// One palette, from the roko mark ("Warp star, graphite"): neutral graphite
/// greys with no blue in them, and one signal orange kept for the few things
/// that must jump out (loading, private mode on, switches, links).
enum Theme {
    static let canvas = Color(light: 0xE6E6E3, dark: 0x0E0E0F)
    static let panel = Color(light: 0xF4F4F2, dark: 0x1A1A1B)
    static let raised = Color(light: 0xFCFCFB, dark: 0x252527)
    static let ink = Color(light: 0x0E0E0F, dark: 0xE7E7E4)
    static let secondaryInk = Color(light: 0x5C5C59, dark: 0x8C8C88)
    // Quiet but still readable: about 4:1 against the panel in both modes.
    static let faintInk = Color(light: 0x737370, dark: 0x7E7E7A)
    /// The mark's orange. In light mode a shade deeper, so it holds on white.
    static let accent = Color(light: 0xE84A10, dark: 0xFF5B1F)
    /// The highlighted row: a neutral lift, not orange, so the accent stays rare.
    static let selection = Color(light: 0x0E0E0F, dark: 0xE7E7E4).opacity(0.08)
    /// The panel's own colour at low opacity: an edge you sense rather than see.
    static let edge = Color(light: 0x0E0E0F, dark: 0xE7E7E4).opacity(0.08)

    static let barHeight: CGFloat = 52
    static let gutter: CGFloat = 16
}

// SwiftUI resolves dynamic colours on its render thread during animations, so
// this must not inherit the project's default main-actor isolation.
extension View {
    /// The floating bar surface: the panel colour, an edge in its own ink, and
    /// one tight shadow cast downward so it lifts off any page, light or dark.
    func barSurface(cornerRadius: CGFloat) -> some View {
        self
            .foregroundStyle(Theme.ink)
            .background(Theme.panel, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.edge))
            .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
    }
}

nonisolated extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
