import SwiftUI
import UIKit

/// One palette, the website's: a warm near-black and a warm off-white, greys with
/// no blue in them, and one red-orange kept for the few things that must jump out
/// (loading, private mode on, switches, links).
enum Theme {
    static let canvas = Color(light: 0xE8E5E0, dark: 0x0F0F0E)
    static let panel = Color(light: 0xF5F3EF, dark: 0x181716)
    static let raised = Color(light: 0xFCFBF9, dark: 0x262523)
    static let ink = Color(light: 0x0F0F0E, dark: 0xF4F1EB)
    static let secondaryInk = Color(light: 0x5E5A53, dark: 0xADA89F)
    /// Text read at length (summaries, answers): a step brighter than
    /// secondaryInk, which made long answers a grey wall, and a step under
    /// ink, so the bold terms and numbers in it still stand out.
    static let bodyInk = Color(light: 0x35322D, dark: 0xBDB8AF)
    // Quiet but still readable: about 4:1 against the panel in both modes.
    static let faintInk = Color(light: 0x75716A, dark: 0x9C978E)
    /// The one signal colour, the same as the website's: it holds on both canvases.
    static let accent = Color(light: 0xC94A2E, dark: 0xC94A2E)
    /// The signal colour for words: thin strokes of it need a step further from
    /// the canvas to stay readable, darker on light and lighter on dark.
    static let accentText = Color(light: 0xB8401F, dark: 0xE8765A)
    /// The highlighted row: a neutral lift, not orange, so the accent stays rare.
    static let selection = Color(light: 0x0F0F0E, dark: 0xF4F1EB).opacity(0.08)
    /// The panel's own colour at low opacity: an edge you sense rather than see.
    static let edge = Color(light: 0x0F0F0E, dark: 0xF4F1EB).opacity(0.08)

    static let barHeight: CGFloat = 52
    /// The bar is a capsule: its 38-point controls sit 11 points in, so their
    /// curves run parallel to its own (19 + 11 = 30, half its height).
    static let barRadius: CGFloat = (barHeight + 8) / 2
    static let gutter: CGFloat = 16
}

extension Font {
    /// A size as designed at the standard text size, following the iPhone's Text Size
    /// setting up to half as large again: past that, these layouts stop reading well.
    static func scaled(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: min(UIFontMetrics.default.scaledValue(for: size), size * 1.5), weight: weight)
    }
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
