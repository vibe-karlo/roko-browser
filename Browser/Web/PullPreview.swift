import SwiftUI
import UIKit

/// What a pull hands the summary when it lets go: the page as it was, how far
/// it had already become the card, and where it was on screen.
struct PullHandoff {
    let snapshot: UIImage
    /// Of the summary's own opening (0: the page, 1: the card at rest).
    let settle: CGFloat
    /// How far down the finger had the card.
    let offset: CGFloat
}

/// The first part of the summary's opening, played by the finger. From the
/// first point of the pull the page is this picture of itself, over the
/// summary's dark: no grey strip above it, no fixed header left behind (WebKit
/// keeps a site's fixed header in place while the page under it moves down).
/// Past the reload point it starts becoming the summary's card: it narrows and
/// its corners round.
/// Let go there and the summary carries on from exactly this frame; ease
/// back and the page settles back to what it was.
///
/// The geometry is SummaryView's, at `settle`: the same inset, height, corners
/// and edge, so the hand-over can't be seen. Cheap: one snapshot per pull,
/// taken as the pull starts; each frame only sets a few frames.
final class PullPreview: UIView {
    /// How far into the opening the pull takes it, at "Summarize".
    static let reach: CGFloat = 0.3

    private let canvas = UIView()
    private let card = UIView()
    private let page = UIImageView()
    private(set) var settle: CGFloat = 0
    private(set) var offset: CGFloat = 0
    private(set) var snapshot: UIImage?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        canvas.backgroundColor = UIColor(Theme.canvas)
        card.clipsToBounds = true
        card.layer.cornerCurve = .continuous
        page.contentMode = .scaleToFill
        addSubview(canvas)
        addSubview(card)
        card.addSubview(page)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(_ snapshot: UIImage) {
        self.snapshot = snapshot
        page.image = snapshot
    }

    var isShowing: Bool { !isHidden }

    /// `progress` 0 at the reload point, 1 at "Summarize"; `pull` how far the
    /// page is down from its top.
    func update(progress: CGFloat, pull: CGFloat) {
        guard let snapshot, let container = superview, let window = container.window else { return }
        let progress = min(max(progress, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isHidden {
            isHidden = false
            frame = container.bounds
            // The dark reaches the very top of the screen, over the status bar strip.
            canvas.frame = window.convert(window.bounds, to: self)
        }
        canvas.alpha = 1
        settle = Self.reach * progress
        offset = pull
        layoutCard(snapshot)
        CATransaction.commit()
    }

    /// SummaryView's card at `settle`, moved down by `offset`.
    private func layoutCard(_ snapshot: UIImage) {
        let width = bounds.width
        let aspect = snapshot.size.height / max(snapshot.size.width, 1)
        let fullHeight = width * aspect
        let inset = 22 * settle
        let cardWidth = width - inset * 2
        card.frame = CGRect(x: inset, y: offset + 12 * settle, width: cardWidth,
                            height: fullHeight + (210 - fullHeight) * settle)
        // Scaled to the card's width, from the top, as SwiftUI's scaledToFill does here.
        page.frame = CGRect(x: 0, y: 0, width: cardWidth, height: cardWidth * aspect)
        card.layer.cornerRadius = 24 * settle
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(Theme.edge).withAlphaComponent(settle).cgColor
    }

    /// Let go short of "Summarize": back to the page, which springs to its top meanwhile.
    func settleBack() {
        guard isShowing, let snapshot else { return hide() }
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.canvas.alpha = 0
            self.settle = 0
            self.offset = 0
            self.layoutCard(snapshot)
        } completion: { _ in
            self.hide()
        }
    }

    /// Handed over: the summary has taken its place.
    func hide() {
        isHidden = true
        settle = 0
        offset = 0
        canvas.alpha = 0
    }

    func handoff() -> PullHandoff? {
        guard isShowing, let snapshot else { return nil }
        return PullHandoff(snapshot: snapshot, settle: settle, offset: offset)
    }
}
