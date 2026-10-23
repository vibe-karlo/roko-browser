import SwiftUI
import WebKit

/// Shows the selected tab's web view. Also listens for the two page gestures:
/// pinching the page smaller to summarize, and scrolling to fold the bar away.
struct WebViewHost: UIViewRepresentable {
    let tab: BrowserTab
    /// Where the floating bar's top edge is, in screen coordinates.
    var barTop: CGFloat
    var onPinchIn: () -> Void
    var onScrollDirection: (_ down: Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        pinch.delegate = context.coordinator
        container.addGestureRecognizer(pinch)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.parent = self
        // Reading isLive (observed) makes SwiftUI call this again when a tab wakes.
        guard tab.isLive, let webView = tab.webView else { return }
        defer { coverBar(webView, in: container) }
        guard webView.superview !== container else { return }

        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        context.coordinator.track(webView, in: container)
    }

    /// The page scrolls under the floating bar, but anything a site pins to the
    /// bottom (cookie bars, chat buttons, "Buy" bars) must sit above it to stay
    /// tappable. Telling WebKit which strip the bar covers does exactly that.
    private func coverBar(_ webView: WKWebView, in container: UIView) {
        guard container.window != nil, barTop > 0 else { return }
        let bottom = container.convert(container.bounds, to: nil).maxY
        let covered = max(0, (bottom - barTop).rounded())
        if webView.obscuredContentInsets.bottom != covered {
            webView.obscuredContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: covered, right: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: WebViewHost
        private var offsetObservation: NSKeyValueObservation?
        private var lastOffset: CGFloat = 0

        init(parent: WebViewHost) {
            self.parent = parent
        }

        func track(_ webView: WKWebView, in container: UIView) {
            let scrollView = webView.scrollView
            addPullToRefresh(to: webView, in: container)
            lastOffset = scrollView.contentOffset.y
            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.scrolled(scrollView) }
            }
        }

        // MARK: Pull to refresh

        private weak var webView: WKWebView?
        private let indicator = PullIndicator()
        private var loadObservations: [NSKeyValueObservation] = []
        private let haptic = UIImpactFeedbackGenerator(style: .light)
        /// How far past the top a pull has to go: long and deliberate, not a bounce.
        private let pullDistance: CGFloat = 120
        /// Pulled far enough, waiting for the finger to lift before reloading.
        private var refreshArmed = false
        /// Reloading for a pull; `sawLoading` once WebKit has actually started.
        private var refreshing = false, sawLoading = false

        /// Pull to refresh, tuned to feel like Safari's: a tap of haptics when
        /// the pull is far enough, the reload only once you let go (reloading
        /// under a moving finger is what makes it stutter), and the ring leaves
        /// as soon as the new page has mostly drawn, not when the last ad finishes.
        private func addPullToRefresh(to webView: WKWebView, in container: UIView) {
            self.webView = webView
            webView.scrollView.refreshControl = nil
            indicator.hide(animated: false)
            container.addSubview(indicator)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 14),
                indicator.widthAnchor.constraint(equalToConstant: PullIndicator.size),
                indicator.heightAnchor.constraint(equalToConstant: PullIndicator.size),
            ])
            webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
            loadObservations = [
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.loadingChanged(webView) }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.loadingChanged(webView) }
                },
            ]
        }

        /// Follows the finger past the top of the page.
        private func pulled(_ scrollView: UIScrollView) {
            guard !refreshing, scrollView.isTracking else { return }
            let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            guard pull > 0 || indicator.alpha > 0 else { return }
            indicator.setProgress(pull / pullDistance)
            if pull >= pullDistance, !refreshArmed {
                refreshArmed = true
                haptic.impactOccurred()
            } else if pull < pullDistance * 0.6, refreshArmed {
                // Pushed back up: changed their mind.
                refreshArmed = false
            }
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began: haptic.prepare()
            case .ended, .cancelled, .failed:
                if refreshArmed { startReload() } else if !refreshing { indicator.hide() }
            default: break
            }
        }

        private func startReload() {
            refreshArmed = false
            refreshing = true
            sawLoading = false
            indicator.spin()
            refreshGeneration += 1
            let generation = refreshGeneration
            webView?.reload()
            // Never leave the spinner up if a page hangs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.refreshGeneration == generation { self?.finishRefresh() }
            }
        }

        private var refreshGeneration = 0

        private func loadingChanged(_ webView: WKWebView) {
            guard refreshing else { return }
            if webView.isLoading { sawLoading = true }
            guard sawLoading, !webView.isLoading || webView.estimatedProgress >= 0.7 else { return }
            finishRefresh()
        }

        private func finishRefresh() {
            guard refreshing else { return }
            refreshing = false
            indicator.hide()
        }

        // MARK: Scrolling

        /// Pinned headers often appear or change colour once you scroll, so the
        /// status bar re-reads it a moment after scrolling stops.
        private var settle: DispatchWorkItem?

        private func scrolled(_ scrollView: UIScrollView) {
            pulled(scrollView)
            // Within a screen and a half of the end, the strip past the page
            // takes the footer's colour. A comparison per frame; the colour
            // itself only changes when this flips.
            // Not at the very top, where a pull to refresh shows the same strip.
            let height = scrollView.bounds.height
            let nearEnd = scrollView.contentOffset.y + height >= scrollView.contentSize.height - height * 1.5
            let resting = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
            parent.tab.showFooterColor(nearEnd && !resting)
            guard scrollView.isTracking || scrollView.isDecelerating else { return }
            settle?.cancel()
            let item = DispatchWorkItem { [weak self, weak scrollView] in
                // Not mid-pull: while the page is stretched past its top, a fixed
                // header reads as not touching the top and the colour would flicker.
                guard let scrollView, scrollView.contentOffset.y >= -scrollView.adjustedContentInset.top - 1 else { return }
                self?.parent.tab.samplePageColors()
            }
            settle = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)

            let offset = scrollView.contentOffset.y
            let delta = offset - lastOffset
            let atTop = offset <= -scrollView.adjustedContentInset.top + 4
            if atTop {
                parent.onScrollDirection(false)
                lastOffset = offset
            } else if abs(delta) > 24 {
                parent.onScrollDirection(delta > 0)
                lastOffset = offset
            }
        }

        private var pinchStartedAtMinimumZoom = false

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = parent.tab.webView?.scrollView else { return }
            switch recognizer.state {
            case .began:
                // Only a pinch that starts on an un-zoomed page means "summarize";
                // otherwise it's an ordinary zoom out.
                pinchStartedAtMinimumZoom = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            case .ended where pinchStartedAtMinimumZoom && recognizer.scale < 0.7:
                parent.onPinchIn()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
