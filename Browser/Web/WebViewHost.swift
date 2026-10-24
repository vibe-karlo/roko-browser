import SwiftUI
import WebKit

/// Shows the selected tab's web view. Also listens for the two page gestures:
/// pulling down past the top to reload or, further, to summarize, and
/// scrolling to fold the bar away.
struct WebViewHost: UIViewRepresentable {
    let tab: BrowserTab
    /// Where the floating bar's top edge is, in screen coordinates.
    var barTop: CGFloat
    var onSummarize: () -> Void
    var onScrollDirection: (_ down: Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
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

    final class Coordinator: NSObject {
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
        /// roko's orange light from the top edge, past the reload point.
        private let light = PullLight()
        private var loadObservations: [NSKeyValueObservation] = []
        private let haptic = UIImpactFeedbackGenerator(style: .light)
        private let firmHaptic = UIImpactFeedbackGenerator(style: .medium)
        /// How far past the top a pull has to go: long and deliberate, not a bounce.
        private let pullDistance: CGFloat = 120
        /// Further still, and letting go summarizes instead of reloading. The
        /// page resists more the further it goes: this is about 370 points of
        /// finger travel, 115 past the reload point's 255.
        private let summarizeDistance: CGFloat = 165
        /// Pulled far enough, waiting for the finger to lift before reloading.
        private var refreshArmed = false
        /// Pulled as far as summarizing, waiting for the finger to lift.
        private var summarizeArmed = false
        /// Let go to summarize: waiting for the page to spring back to its top.
        private var summarizePending = false
        /// The page behind the pull is light (white, mostly): the light's colours follow it.
        private var pageIsLight = true
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
            light.alpha = 0
            container.insertSubview(light, belowSubview: indicator)
            PullLight.prepare()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            // Its own width: a circle, or a capsule once it says "Summarize".
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 14),
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
            guard !refreshing, !summarizePending, scrollView.isTracking else { return }
            let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            guard pull > 0 || indicator.alpha > 0 else { return }
            indicator.setProgress(pull <= pullDistance
                                  ? pull / pullDistance
                                  : 1 + (pull - pullDistance) / (summarizeDistance - pullDistance))
            // Past the reload point the light pours in, full once a release summarizes.
            light.setStrength((pull - pullDistance) / (summarizeDistance - pullDistance), onLightPage: pageIsLight)
            if pull >= pullDistance, !refreshArmed {
                refreshArmed = true
                haptic.impactOccurred()
            } else if pull < pullDistance * 0.6, refreshArmed {
                // Pushed back up: changed their mind.
                refreshArmed = false
            }
            // A firmer tap as it turns into "Summarize"; easing back off a
            // little takes it back to a reload.
            if pull >= summarizeDistance, !summarizeArmed {
                summarizeArmed = true
                indicator.setSummarize(true)
                firmHaptic.impactOccurred()
            } else if pull < summarizeDistance - 20, summarizeArmed {
                summarizeArmed = false
                indicator.setSummarize(false)
            }
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                haptic.prepare()
                firmHaptic.prepare()
                // A pull from the top may reach the light: draw it now (once
                // per appearance, a millisecond or two), not mid-pull.
                if let scrollView = pan.view as? UIScrollView,
                   scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1 {
                    let start = CACurrentMediaTime()
                    pageIsLight = Self.isLight(webView?.underPageBackgroundColor)
                    _ = PullLight.image(onLightPage: pageIsLight)
                    if LaunchClock.isEnabled { print(String(format: "PERF pullLight %.2fms", (CACurrentMediaTime() - start) * 1000)) }
                }
            case .ended, .cancelled, .failed:
                if summarizeArmed {
                    // The light goes as the page springs back; the summary
                    // brings its own.
                    light.fadeOut(duration: 0.45)
                    startSummarize()
                } else {
                    light.fadeOut(duration: 0.2)
                    if refreshArmed {
                        startReload()
                    } else if !refreshing {
                        indicator.hide()
                    }
                }
            default: break
            }
        }

        /// The page springs back to its top first, so the summary opens from
        /// the page as it reads, not from the gap above it. "Summarize" stays
        /// up meanwhile.
        private func startSummarize() {
            summarizeArmed = false
            refreshArmed = false
            summarizePending = true
            // Never wait on a page that doesn't spring back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finishSummarize() }
        }

        private func finishSummarize() {
            guard summarizePending else { return }
            summarizePending = false
            indicator.hide()
            parent.onSummarize()
        }

        private static func isLight(_ color: UIColor?) -> Bool {
            var white: CGFloat = 1, alpha: CGFloat = 1
            guard let color, color.getWhite(&white, alpha: &alpha) else { return true }
            return white > 0.5
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
        private var lastScrollAt: CFTimeInterval = 0
        private var settleScheduled = false

        /// Once scrolling has been still for 0.3 s, re-read the page's edge colours.
        private func scheduleSettleCheck(_ scrollView: UIScrollView) {
            settleScheduled = true
            let wait = max(0.05, lastScrollAt + 0.3 - CACurrentMediaTime())
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                if CACurrentMediaTime() - self.lastScrollAt < 0.3 {
                    self.scheduleSettleCheck(scrollView)
                    return
                }
                self.settleScheduled = false
                // Not mid-pull: while the page is stretched past its top, a fixed
                // header reads as not touching the top and the colour would flicker.
                guard scrollView.contentOffset.y >= -scrollView.adjustedContentInset.top - 1 else { return }
                self.parent.tab.samplePageColors()
            }
        }

        private func scrolled(_ scrollView: UIScrollView) {
            if summarizePending, scrollView.contentOffset.y >= -scrollView.adjustedContentInset.top - 0.5 {
                finishSummarize()
            }
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
            // One pending check at a time, not a new one every frame.
            lastScrollAt = CACurrentMediaTime()
            if !settleScheduled { scheduleSettleCheck(scrollView) }

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

    }
}
