import SwiftUI
import UIKit

/// The pull-to-refresh mark: a ring that fills as you pull, spins while the
/// page reloads, then fades. It floats above the page, so a site's fixed header
/// can't hide it, and it never pushes the page content down, which is what
/// makes the system control feel jerky on a web view.
final class PullIndicator: UIView {
    static let size: CGFloat = 34
    private let ring = CAShapeLayer()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = UIColor(Theme.panel)
        layer.cornerRadius = Self.size / 2
        // The bar's tight, downward shadow, so it reads on any page.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath

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
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PullIndicator, _) in view.updateColors() }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateColors() {
        ring.strokeColor = UIColor(Theme.ink).resolvedColor(with: traitCollection).cgColor
    }

    /// 0 to 1 while pulling; full at the point a release would reload.
    func setProgress(_ progress: CGFloat) {
        guard ring.animation(forKey: "spin") == nil else { return }
        let progress = min(max(progress, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = progress * 0.85
        ring.setAffineTransform(CGAffineTransform(rotationAngle: progress * .pi))
        CATransaction.commit()
        alpha = min(progress * 2.5, 1)
        transform = CGAffineTransform(scaleX: 0.7 + 0.3 * progress, y: 0.7 + 0.3 * progress)
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
            self?.ring.removeAnimation(forKey: "spin")
            self?.ring.strokeEnd = 0
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
