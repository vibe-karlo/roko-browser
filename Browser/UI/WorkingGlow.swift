import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Warm light rising from the bottom edge while Browse for Me finds an answer.
/// It has a job, so the wait has something to watch: it climbs as pages are
/// read (`progress`, 0 to 1) and breathes slowly while it waits. It leaves as
/// soon as the answer starts, so it never sits behind text being read.
///
/// Cheap by construction: one gradient and one still grain, moved only by
/// scale and opacity, which the GPU animates with no work per frame on the CPU.
/// With Reduce Motion it holds still.
struct WorkingGlow: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            // How far up the light reaches: a low dawn at first, about half the
            // screen once the pages are read.
            let reach = height * (0.2 + 0.32 * progress)

            light
                // An ellipse centred on the bottom edge: only its top half shows,
                // as light coming from below the screen rather than a blob on it.
                .frame(width: width * 1.9, height: reach * 2)
                .position(x: width / 2, y: height)
                .scaleEffect(x: 1, y: breathing ? 1.07 : 0.96, anchor: .bottom)
                .opacity(breathing ? 1 : 0.8)
        }
        .animation(.easeInOut(duration: 1.1), value: progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { breathing = true }
        }
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
