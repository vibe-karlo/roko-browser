import SwiftUI
import UIKit

/// roko's light, pouring in from the top edge while a pull would summarize:
/// nothing during the plain reload stage, then it grows past the reload point
/// and is full once "Summarize" shows. Orange means roko's AI, as the light
/// behind Browse for Me and Summarize does.
///
/// Cheap by construction: the light is drawn once per appearance (light or
/// dark) into a small image, and a pull only moves, stretches and fades that
/// image. No frame redraws anything.
final class PullLight: UIImageView {
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        contentMode = .scaleToFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How much of the screen the full light reaches down.
    private static let reach: CGFloat = 0.7

    /// 0: none (reload stage). 1: full (a release summarizes). Its top stays at
    /// the screen's top edge; it grows down from there. `onLightPage`: the
    /// colours follow the page it shines on, not the phone's appearance.
    func setStrength(_ strength: CGFloat, onLightPage: Bool) {
        let strength = min(max(strength, 0), 1)
        guard let container = superview, let window = container.window else { return }
        if strength > 0, alpha == 0 {
            // Placed when it first shows: from the very top of the screen, over
            // the status bar strip, so it doesn't start at a seam below it.
            image = Self.image(onLightPage: onLightPage)
            transform = .identity
            let top = -container.convert(CGPoint.zero, to: window).y
            let width = container.bounds.width
            frame = CGRect(x: -width * 0.3, y: top, width: width * 1.6, height: window.bounds.height * Self.reach)
        }
        let height = bounds.height
        let stretch = 0.3 + 0.7 * strength
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Stretched about its centre, then lifted so the top stays at the edge.
        transform = CGAffineTransform(translationX: 0, y: -height * (1 - stretch) / 2).scaledBy(x: 1, y: stretch)
        alpha = strength
        CATransaction.commit()
    }

    func fadeOut(duration: TimeInterval) {
        guard alpha > 0 else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.alpha = 0
        }
    }

    // MARK: Drawing

    private static var images: [Bool: UIImage] = [:]
    private static var preparing = false

    /// Draws both versions off the main thread, a moment after the first page
    /// shows, so no pull ever waits for them (drawn on the spot, the first took 15 ms).
    static func prepare() {
        guard !preparing, images.count < 2 else { return }
        preparing = true
        let wanted = [true, false].filter { images[$0] == nil }.map { ($0, colors(onLightPage: $0)) }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1.5))
            let drawn = wanted.map { ($0.0, draw($0.1)) }
            await MainActor.run {
                for (onLightPage, image) in drawn where images[onLightPage] == nil { images[onLightPage] = image }
            }
        }
    }

    /// The light for a page; drawn here only if a pull beat `prepare` to it.
    static func image(onLightPage: Bool) -> UIImage {
        if let cached = images[onLightPage] { return cached }
        let image = draw(colors(onLightPage: onLightPage))
        images[onLightPage] = image
        return image
    }

    /// WorkingGlow's stops, in the orange for the page's brightness. On a light
    /// page it warms toward amber, more than in WorkingGlow: over white, plain
    /// orange light reads as salmon.
    private static func colors(onLightPage: Bool) -> [CGColor] {
        let traits = UITraitCollection(userInterfaceStyle: onLightPage ? .light : .dark)
        let accent = UIColor(Theme.accent).resolvedColor(with: traits)
        let amber = UIColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1)
        return stops.map { stop in
            let warmth = onLightPage ? min(1, stop.warmth + 0.3) : 0
            return mix(accent, amber, warmth).withAlphaComponent(stop.alpha).cgColor
        }
    }

    /// Stronger than WorkingGlow's: it only shows for the moment of a pull, over a page.
    private static let stops: [(alpha: CGFloat, warmth: CGFloat, location: CGFloat)] = [
        (0.95, 0, 0), (0.78, 0.25, 0.16), (0.55, 0.5, 0.34), (0.32, 0.65, 0.52), (0.13, 0.8, 0.72), (0, 0.8, 1),
    ]

    /// The lower half of an ellipse centred on the top edge, with grain
    /// dithered into it so it can't band. Safe on any thread.
    nonisolated private static func draw(_ colors: [CGColor]) -> UIImage {
        let size = CGSize(width: 320, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let locations: [CGFloat] = [0, 0.16, 0.34, 0.52, 0.72, 1]
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                            locations: locations) else { return }
            cg.saveGState()
            cg.translateBy(x: size.width / 2, y: 0)
            cg.scaleBy(x: size.width / 2, y: size.height)
            cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            cg.restoreGState()
            // Grain only where there's light: atop keeps the light's own alpha.
            if let grain = Grain.image?.cgImage {
                cg.setBlendMode(.sourceAtop)
                cg.setAlpha(0.1)
                cg.draw(grain, in: CGRect(x: 0, y: 0, width: 64, height: 64), byTiling: true)
            }
        }
    }

    private static func mix(_ a: UIColor, _ b: UIColor, _ amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }
}
