import SwiftUI

/// Warm light rising from the bottom edge while Browse for Me finds an answer.
/// It has a job, so the wait has something to watch: it climbs as pages are
/// read (`progress`, 0 to 1) and breathes slowly while it waits. It leaves as
/// soon as the answer starts, so it never sits behind text being read.
///
/// Smooth by construction: the light is drawn once, at full size, and only
/// scaled and faded after that, so no frame redraws the gradient or the grain;
/// the GPU does the rest. Progress arrives in steps (a page read, then another),
/// so it's carried by a critically damped spring: a new target bends the motion
/// already under way instead of restarting it, and the steps blend into one
/// continuous rise. With Reduce Motion it holds still.
///
/// It stays in place and leaves on its own (`isActive` false): it sinks back
/// into the edge as it fades, then stops breathing, so a hidden light costs
/// nothing. (Removing it with a transition instead skipped the animation.)
/// When it leaves because the answer arrived (`finished`), it floods the
/// whole screen instead, and dissolves as the answer settles in.
struct WorkingGlow: View {
    let progress: Double
    var isActive = true
    /// The work it stood for is done: it leaves by flooding, not sinking.
    var finished = false
    /// Off for a light that stands for nothing being worked on (Today's
    /// morning light): it holds still, and costs no frames.
    var breathes = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// The progress actually drawn, easing after `progress`.
    @State private var shown: Double?
    @State private var breathing = false
    /// Faded in once on first appearance.
    @State private var appeared = false
    /// The flood: its layer is in (`flooding`), risen over the screen (`floodUp`), gone (`dissolved`).
    @State private var flooding = false
    @State private var floodUp = false
    @State private var dissolved = false

    /// From a low dawn to most of the screen, as a share of the full light.
    private static let lowest = 0.25, highest = 0.85
    /// The warm end of the light's falloff on the light canvas.
    private static let amber = Color(red: 0.96, green: 0.65, blue: 0.14)

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let width = proxy.size.width, height = proxy.size.height
                let reach = (Self.lowest + (Self.highest - Self.lowest) * (shown ?? progress)) / Self.highest

                light
                    // An ellipse centred on the bottom edge: only its top half shows,
                    // as light coming from below the screen rather than a blob on it.
                    .frame(width: width * 1.9, height: height * Self.highest * 2)
                    // Scaled about that centre, it rises from and sinks into the edge.
                    .scaleEffect(x: 1, y: reach)
                    .scaleEffect(x: breathing ? 1.02 : 0.99, y: breathing ? 1.06 : 0.97)
                    .position(x: width / 2, y: height)
                    .opacity((breathing ? 1 : 0.84) * (0.8 + 0.2 * (shown ?? progress)))
            }
            // Arriving it rises out of the edge; leaving, it sinks back into it.
            .scaleEffect(x: 1, y: lit ? 1 : 0.6, anchor: .bottom)
            .opacity(lit ? 1 : 0)
            .animation(.easeInOut(duration: lit ? 0.7 : 0.9), value: lit)

            if flooding { floodLayer }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            shown = progress
            appeared = true
            if isActive { breathe() }
        }
        .onChange(of: progress) { _, target in
            withAnimation(reduceMotion ? nil : .spring(duration: 2.4, bounce: 0)) { shown = target }
        }
        .onChange(of: isActive) { _, active in
            if active {
                breathe()
            } else {
                if finished, !reduceMotion { flood() }
                // Once it has gone, stop the breathing: no frames for a hidden light.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    guard !isActive else { return }
                    withTransaction(Transaction(animation: nil)) {
                        breathing = false
                        flooding = false
                        floodUp = false
                        dissolved = false
                    }
                }
            }
        }
    }

    private var lit: Bool { appeared && isActive }

    /// The flood, a layer of its own: the same light drawn big enough to
    /// cover the screen, so its grain stays fine. Stretching the rising
    /// light up to the top instead turned the grain into coarse static.
    private var floodLayer: some View {
        GeometryReader { proxy in
            light
                .frame(width: proxy.size.width * 2.2, height: proxy.size.height * 4)
                .position(x: proxy.size.width / 2, y: proxy.size.height)
        }
        .scaleEffect(x: 1, y: floodUp ? 1 : 0.45, anchor: .bottom)
        .opacity(floodUp && !dissolved ? 1 : 0)
    }

    /// Up over the screen fast as the rising light gives way to it, then gone
    /// more slowly, so the answer arrives in the light.
    private func flood() {
        flooding = true
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.45)) { floodUp = true }
            withAnimation(.easeInOut(duration: 0.75).delay(0.4)) { dissolved = true }
        }
    }

    /// How long a flood lasts, for views that keep their edges clear meanwhile.
    static let floodDuration: TimeInterval = 1.2

    private func breathe() {
        guard breathes, !reduceMotion, !breathing else { return }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathing = true }
    }

    /// The accent, falling off over many stops so it eases out rather than
    /// ending in a ring, with grain on top so the falloff can't band.
    private var light: some View {
        // Over the light canvas the accent's faint tail reads as pink, so there
        // it warms toward amber as it falls off: sunlight, not a pink wash.
        let warms = colorScheme == .light
        func shade(_ opacity: Double, warmth: Double) -> Color {
            (warms ? Theme.accent.mix(with: Self.amber, by: warmth) : Theme.accent).opacity(opacity)
        }
        // Strong at the edge it rises from: at half strength over the near-black
        // canvas, orange reads as rust, not light.
        let falloff = EllipticalGradient(stops: [
            .init(color: shade(0.85, warmth: 0), location: 0),
            .init(color: shade(0.6, warmth: 0.25), location: 0.16),
            .init(color: shade(0.38, warmth: 0.5), location: 0.34),
            .init(color: shade(0.2, warmth: 0.65), location: 0.52),
            .init(color: shade(0.08, warmth: 0.8), location: 0.72),
            .init(color: shade(0, warmth: 0.8), location: 1),
        ], center: .center)
        return falloff
            .overlay {
                if let grain = Grain.image {
                    Image(uiImage: grain)
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(0.28)
                        .mask(falloff)
                }
            }
    }
}

/// A small tile of fine monochrome noise, made once from random bytes.
/// (Core Image made it in 90 ms, most of it setting up a CIContext: a hitch
/// the first time a light showed. This takes well under a millisecond.)
nonisolated enum Grain {
    static let image: UIImage? = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        arc4random_buf(&pixels, pixels.count)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }()
}
