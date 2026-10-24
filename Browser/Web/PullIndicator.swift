import SwiftUI
import UIKit

/// The pull mark: a ring that fills as you pull, spins while the page
/// reloads, then fades. Pulled on past the reload point, the ring closes and
/// the mark opens into "Summarize": letting go there summarizes instead. It
/// floats above the page, so a site's fixed header can't hide it, and it never
/// pushes the page content down, which is what makes the system control feel
/// jerky on a web view.
final class PullIndicator: UIView {
    static let size: CGFloat = 34
    private let ring = CAShapeLayer()
    private let glyph = UIImageView(image: UIImage(named: "phosphor/summarize")?.withRenderingMode(.alwaysTemplate))
    private let label = UILabel()
    /// Showing "Summarize": a release now summarizes the page.
    private(set) var showsSummarize = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = UIColor(Theme.panel)
        // Half the height at any width: a circle, opening into a capsule.
        layer.cornerRadius = Self.size / 2
        // The bar's tight, downward shadow, so it reads on any page. No fixed
        // path: the shadow follows the shape as it widens.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let inset: CGFloat = 9
        ring.frame = bounds
        // Starts at twelve o'clock and runs clockwise.
        ring.path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - inset,
                                 startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        ring.fillColor = nil
        ring.lineWidth = 2.2
        ring.lineCap = .round
        ring.strokeEnd = 0
        layer.addSublayer(ring)

        glyph.contentMode = .scaleAspectFit
        glyph.alpha = 0
        addSubview(glyph)
        label.text = "Summarize"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alpha = 0
        addSubview(label)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PullIndicator, _) in view.updateColors() }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private enum Layout {
        static let leading: CGFloat = 12, glyph: CGFloat = 18, gap: CGFloat = 7, trailing: CGFloat = 15
    }

    override var intrinsicContentSize: CGSize {
        guard showsSummarize else { return CGSize(width: Self.size, height: Self.size) }
        let width = Layout.leading + Layout.glyph + Layout.gap + label.intrinsicContentSize.width + Layout.trailing
        return CGSize(width: width.rounded(.up), height: Self.size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The ring stays centred in the circle; the glyph and word sit at the
        // leading edge, so they're revealed as the capsule opens around them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        glyph.frame = CGRect(x: Layout.leading, y: (bounds.height - Layout.glyph) / 2,
                             width: Layout.glyph, height: Layout.glyph)
        let text = label.intrinsicContentSize
        label.frame = CGRect(x: glyph.frame.maxX + Layout.gap, y: (bounds.height - text.height) / 2,
                             width: text.width, height: text.height)
    }

    private func updateColors() {
        backgroundColor = UIColor(Theme.panel)
        let ink = UIColor(Theme.ink).resolvedColor(with: traitCollection)
        ring.strokeColor = ink.cgColor
        glyph.tintColor = ink
        label.textColor = ink
    }

    /// 0 to 1 while pulling to the reload point; on to 2 at the summarize point,
    /// closing the ring.
    func setProgress(_ progress: CGFloat) {
        guard ring.animation(forKey: "spin") == nil else { return }
        let progress = min(max(progress, 0), 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = progress <= 1 ? progress * 0.85 : 0.85 + (progress - 1) * 0.15
        ring.setAffineTransform(CGAffineTransform(rotationAngle: progress * .pi))
        CATransaction.commit()
        let reached = min(progress, 1)
        alpha = min(reached * 2.5, 1)
        transform = CGAffineTransform(scaleX: 0.7 + 0.3 * reached, y: 0.7 + 0.3 * reached)
    }

    /// Opens into "Summarize", or closes back into the ring.
    func setSummarize(_ on: Bool) {
        guard on != showsSummarize else { return }
        showsSummarize = on
        invalidateIntrinsicContentSize()
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            self.superview?.layoutIfNeeded()
            self.glyph.alpha = on ? 1 : 0
            self.label.alpha = on ? 1 : 0
        }
        // The ring goes at once rather than sliding under the word.
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.12 : 0.25)
        ring.opacity = on ? 0 : 1
        CATransaction.commit()
    }

    func spin() {
        ring.strokeEnd = 0.85
        transform = .identity
        alpha = 1
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = ring.value(forKeyPath: "transform.rotation.z")
        spin.byValue = 2 * Double.pi
        spin.duration = 0.75
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    func hide(animated: Bool = true) {
        let finish = { [weak self] in
            guard let self else { return }
            ring.removeAnimation(forKey: "spin")
            ring.strokeEnd = 0
            // Back to a plain circle, unseen, for the next pull.
            if showsSummarize {
                showsSummarize = false
                invalidateIntrinsicContentSize()
                superview?.layoutIfNeeded()
                glyph.alpha = 0
                label.alpha = 0
                ring.opacity = 1
            }
        }
        guard animated else {
            alpha = 0
            finish()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        } completion: { _ in
            if self.alpha == 0 { finish() }
        }
    }
}
