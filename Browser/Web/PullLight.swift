import SwiftUI
import UIKit

/// A dusk falling from the top edge while a pull would summarize: nothing
/// during the plain reload stage, then it deepens past the reload point and
/// is full once "Summarize" shows. It's the summary's own dark, so a release
/// hands straight into the summary instead of an orange wash over the page.
///
/// Cheap by construction: the shade is drawn once per appearance (light or
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
            frame = CGRect(x: 0, y: top, width: width, height: window.bounds.height * Self.reach)
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

    /// The summary's canvas, falling off over many stops so it eases out
    /// rather than ending in a line. Deeper over a light page, where a faint
    /// dark reads as grey haze rather than dusk.
    private static func colors(onLightPage: Bool) -> [CGColor] {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let dusk = UIColor(Theme.canvas).resolvedColor(with: traits)
        let strength: CGFloat = onLightPage ? 1 : 0.9
        return stops.map { dusk.withAlphaComponent($0 * strength).cgColor }
    }

    /// Eased: most of the shade near the edge, a long soft tail.
    private static let stops: [CGFloat] = [0.96, 0.9, 0.78, 0.6, 0.4, 0.22, 0.09, 0.02, 0]
    private static let locations: [CGFloat] = [0, 0.12, 0.25, 0.38, 0.52, 0.66, 0.8, 0.92, 1]

    /// A vertical fall-off, drawn tall so stretching it never shows steps.
    /// Safe on any thread.
    nonisolated private static func draw(_ colors: [CGColor]) -> UIImage {
        let size = CGSize(width: 4, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .extended
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.extendedSRGB), colors: colors as CFArray,
                                            locations: locations) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
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
