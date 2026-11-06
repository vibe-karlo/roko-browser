import SwiftUI

/// Exploration: what the band under the page stands on, a dim shade of the
/// site's own colour (after Arc's space colour, but the page chooses it), and
/// a warm graphite for pages with no colour of their own. Always dark, so the bar's
/// keys read the same on every site.
struct BandGround: View {
    let color: UIColor?

    var body: some View {
        let shades = color?.bandShades ?? (Color(uiColor: UIColor(hex: 0x131211)), Color(uiColor: UIColor(hex: 0x201E1C)))
        shades.0
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [shades.0, shades.1], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
            .animation(.easeOut(duration: 0.35), value: color)
    }
}

extension UIColor {
    /// A tab card with no picture: the site's colour, lifted to sit on the band.
    var cardShade: Color? {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha),
              saturation > 0.15, brightness > 0.08 else { return nil }
        return Color(hue: hue, saturation: min(saturation, 0.6), brightness: 0.45)
    }
}

extension UIImage {
    /// All one colour, near enough, read from an averaged 16 by 16 copy: a page not yet painted.
    var isOneColour: Bool {
        guard let cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drew else { return false }
        return (0..<3).allSatisfy { channel in
            let values = stride(from: channel, to: pixels.count, by: 4).map { pixels[$0] }
            return (values.max() ?? 0) - (values.min() ?? 0) < 6
        }
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

/// The band's ground for one of roko's own screens, drawn over what scrolls under
/// it, its top corners cut in a curve so the screen above reads as the same rounded
/// card a page is. `lip` is how far the corners reach above the band.
nonisolated struct BandFloor: Shape {
    static let lip: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + Self.lip
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + Self.lip, y: rect.minY), radius: Self.lip,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX - Self.lip, y: top))
        path.addArc(center: CGPoint(x: rect.maxX - Self.lip, y: rect.minY), radius: Self.lip,
                    startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
