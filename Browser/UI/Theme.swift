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
    /// Text read at length (summaries, answers): a step brighter than
    /// secondaryInk, which made long answers a grey wall, and a step under
    /// ink, so the bold terms and numbers in it still stand out.
    static let bodyInk = Color(light: 0x34342F, dark: 0xB8B8B3)
    // Quiet but still readable: about 4:1 against the panel in both modes.
    static let faintInk = Color(light: 0x737370, dark: 0x7E7E7A)
    /// The mark's orange. In light mode a shade deeper, so it holds on white.
    static let accent = Color(light: 0xE84A10, dark: 0xFF5B1F)
    /// The mark's orange for words: thin strokes of it read redder than a
    /// filled shape does, so text gets a step lighter on dark and a warmer
    /// step on light, and still reads as the same orange as the switches.
    static let accentText = Color(light: 0xD4570C, dark: 0xFF7A38)
    /// The highlighted row: a neutral lift, not orange, so the accent stays rare.
    static let selection = Color(light: 0x0E0E0F, dark: 0xE7E7E4).opacity(0.08)
    /// The panel's own colour at low opacity: an edge you sense rather than see.
    static let edge = Color(light: 0x0E0E0F, dark: 0xE7E7E4).opacity(0.08)

    static let barHeight: CGFloat = 52
    /// The bar is a capsule: its 38-point controls sit 11 points in, so their
    /// curves run parallel to its own (19 + 11 = 30, half its height).
    static let barRadius: CGFloat = (barHeight + 8) / 2
    static let gutter: CGFloat = 16
}

/// Settings → Appearance: follow iOS, or stay light or dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Set on the windows rather than in SwiftUI, so everything follows:
    /// sheets, the system Paste button, and pages that have a dark mode.
    static func apply() {
        let chosen = UserDefaults.standard.string(forKey: key).flatMap(Appearance.init) ?? .system
        let style: UIUserInterfaceStyle = switch chosen {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
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
