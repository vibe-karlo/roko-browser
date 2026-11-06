import SwiftUI

/// Exploration: what the band under the page stands on, a dim shade of the
/// site's own colour (after Arc's space colour, but the page chooses it), and
/// graphite for pages with no colour of their own. Always dark, so the bar's
/// keys read the same on every site.
struct BandGround: View {
    let color: UIColor?

    var body: some View {
        let shades = color?.bandShades ?? (Color(uiColor: UIColor(hex: 0x101011)), Color(uiColor: UIColor(hex: 0x1D1D1E)))
        shades.0
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [shades.0, shades.1], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
            .animation(.easeOut(duration: 0.35), value: color)
    }
}

private extension UIColor {
    /// The band's top and foot, or nil when the colour is too grey or too dark to name a hue.
    var bandShades: (Color, Color)? {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha),
              saturation > 0.15, brightness > 0.08 else { return nil }
        // Oranges and yellows go brown when dimmed: closer to warm charcoal, they stay clean.
        let muddy = hue > 0.05 && hue < 0.19
        let kept = min(saturation, 0.7) * (muddy ? 0.45 : 0.8)
        return (Color(hue: hue, saturation: kept, brightness: 0.13),
                Color(hue: hue, saturation: kept, brightness: 0.23))
    }
}

/// The loading line, growing both ways from the middle of the card's bottom
/// edge, under the +, and reaching round the corners only as it finishes. A view of its own, so each step of progress redraws only this.
struct CardEdgeProgress: View {
    let tab: BrowserTab?
    let radius: CGFloat

    var body: some View {
        if let tab, tab.isLoading {
            CardBottomEdge(radius: radius, inset: 1.25)
                .trim(from: 0.5 - max(0.01, tab.progress) / 2, to: 0.5 + max(0.01, tab.progress) / 2)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .animation(.easeOut(duration: 0.25), value: tab.progress)
                .transition(.opacity)
        }
    }
}

/// The card's bottom edge in a breath of white, so dark content under it
/// doesn't melt into the band and lose the curve.
struct CardEdgeLip: View {
    let radius: CGFloat

    var body: some View {
        CardBottomEdge(radius: radius, inset: 0.25)
            .stroke(.white.opacity(0.1), lineWidth: 0.5)
    }
}

/// The left corner, the foot and the right corner, in from the edge by half
/// the stroke's width so it sits whole inside the card.
private nonisolated struct CardBottomEdge: Shape {
    let radius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: inset, dy: inset)
        let curve = radius - inset
        var path = Path()
        path.move(to: CGPoint(x: inner.minX, y: inner.maxY - curve))
        path.addArc(center: CGPoint(x: inner.minX + curve, y: inner.maxY - curve), radius: curve,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: inner.maxX - curve, y: inner.maxY))
        path.addArc(center: CGPoint(x: inner.maxX - curve, y: inner.maxY - curve), radius: curve,
                    startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        return path
    }
}
