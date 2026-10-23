import CoreImage
import CoreImage.CIFilterBuiltins
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
struct WorkingGlow: View {
    let progress: Double
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The progress actually drawn, easing after `progress`.
    @State private var shown: Double?
    @State private var breathing = false
    /// Faded in once on first appearance.
    @State private var appeared = false

    /// From a low dawn to about half the screen, as a share of the full light.
    private static let lowest = 0.2, highest = 0.52

    var body: some View {
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
                // Once it has faded out, stop the breathing: no frames for a hidden light.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard !isActive else { return }
                    withTransaction(Transaction(animation: nil)) { breathing = false }
                }
            }
        }
    }

    private var lit: Bool { appeared && isActive }

    private func breathe() {
        guard !reduceMotion, !breathing else { return }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathing = true }
    }

    /// The accent, falling off over many stops so it eases out rather than
    /// ending in a ring, with grain on top so the falloff can't band.
    private var light: some View {
        // Strong at the edge it rises from: at half strength over the near-black
        // canvas, orange reads as rust, not light.
        let falloff = EllipticalGradient(stops: [
            .init(color: Theme.accent.opacity(0.85), location: 0),
            .init(color: Theme.accent.opacity(0.6), location: 0.16),
            .init(color: Theme.accent.opacity(0.38), location: 0.34),
            .init(color: Theme.accent.opacity(0.2), location: 0.52),
            .init(color: Theme.accent.opacity(0.08), location: 0.72),
            .init(color: Theme.accent.opacity(0), location: 1),
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

/// A small tile of fine monochrome noise, made once with Core Image.
enum Grain {
    static let image: UIImage? = {
        let noise = CIFilter.randomGenerator().outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let noise, let cgImage = CIContext().createCGImage(noise, from: noise.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }()
}
