import SwiftUI

/// roko's light, while Browse for Me or a summary works: one light from start to
/// finish. It rises from the bottom edge as pages are read (`progress`, 0 to 1) and
/// breathes slowly while it waits, so the wait has something to watch. When the
/// answer arrives (`finished`) its top edge catches and it carries on up, off the
/// top of the screen, and the answer arrives in its wake. Otherwise it sinks back
/// into the edge. It never sits behind text being read.
///
/// Light by construction: two small pictures drawn once and moved by Core Animation
/// (`LightView`). The app draws no frames for it, so it costs next to nothing while
/// it runs, and a main thread busy reading a page can't make it stutter.
/// With Reduce Motion it holds still and only fades.
struct WorkingGlow: View {
    let progress: Double
    var isActive = true
    /// The work it stood for is done: it leaves upward, not by sinking.
    var finished = false
    /// Off for a light that stands for nothing being worked on (Today's
    /// morning light): it holds still.
    var breathes = true
    /// Where along the bottom edge it rises from, 0 to 1. Changes glide.
    var across = 0.5
    /// How bright it is, 0 to 1. Changes glide.
    var strength = 1.0
    /// Wanders slowly from side to side as it breathes (the welcome's light).
    var drifts = false
    var riseDuration: TimeInterval = 0.7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long leaving upward takes, for views that keep their edges clear meanwhile.
    static let sweepDuration: TimeInterval = LightView.sweepDuration

    var body: some View {
        LightLayers(wanted: .init(progress: progress, isActive: isActive, finished: finished, breathes: breathes,
                                  across: across, strength: strength, drifts: drifts, riseDuration: riseDuration,
                                  still: reduceMotion))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LightLayers: UIViewRepresentable {
    let wanted: LightView.Wanted

    func makeUIView(context: Context) -> LightView { LightView() }

    func updateUIView(_ view: LightView, context: Context) {
        view.wanted = wanted
    }
}

/// The layers: `dome`, the light itself, inside `breath` and `risen`, which carry
/// its slow breathing and its arriving and leaving; `crest`, the bright edge it
/// catches on leaving; and `grain`, which keeps the long falloffs from banding.
/// All of them are hidden once it has gone, so a dark light isn't even composited.
final class LightView: UIView {
    struct Wanted: Equatable {
        var progress: Double
        var isActive: Bool
        var finished: Bool
        var breathes: Bool
        var across: Double
        var strength: Double
        var drifts: Bool
        var riseDuration: TimeInterval
        var still: Bool
    }

    static let sweepDuration: TimeInterval = 1.2
    /// How long the crest takes to cross; the fade finishes after it's gone.
    private static let crossing: TimeInterval = 0.85
    /// From a low dawn to most of the screen, as a share of its height.
    private static let lowest = 0.25, highest = 0.85
    /// Where on the dome its edge seems to be, as a share of the dome's height:
    /// the crest catches there, and stays there as both carry on up.
    private static let edge = 0.62
    /// Where the crest's bright lip is in its picture, and how much of the screen the picture covers.
    private static let lipAt = 0.1, crestDepth = 0.56
    private static let travel = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)

    private let risen = CALayer(), breath = CALayer(), dome = CALayer(), crest = CALayer()
    /// One small tile, repeated by the two replicators: a whole screen's worth of
    /// noise for the memory of a thumbnail. (A pattern colour cost 10 MB.)
    private let grain = CALayer(), grainRows = CAReplicatorLayer(), grainColumns = CAReplicatorLayer(), grainTile = CALayer()
    private var isLit = false
    private var isLeaving = false
    /// Tells a leaving's cleanup that the light has come back since.
    private var generation = 0
    private var level = 0.0, across = 0.5, strength = 1.0
    private var drawnStyle: UIUserInterfaceStyle?

    var wanted: Wanted? {
        didSet { if wanted != oldValue { settle() } }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(grain)
        layer.addSublayer(risen)
        layer.addSublayer(crest)
        risen.addSublayer(breath)
        breath.addSublayer(dome)
        for sublayer in [risen, breath, dome, crest] {
            sublayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        }
        crest.anchorPoint = CGPoint(x: 0.5, y: Self.lipAt)
        for sublayer in [grain, risen, crest] { sublayer.opacity = 0 }
        grain.addSublayer(grainRows)
        grainRows.addSublayer(grainColumns)
        grainColumns.addSublayer(grainTile)
        let tile = Grain.dither
        grainTile.contents = tile?.cgImage
        grainTile.contentsScale = tile?.scale ?? 3
        grainTile.magnificationFilter = .nearest
        grainTile.frame = CGRect(origin: .zero, size: tile?.size ?? .zero)
        grainColumns.instanceTransform = CATransform3DMakeTranslation(grainTile.bounds.width, 0, 0)
        grainRows.instanceTransform = CATransform3DMakeTranslation(0, grainTile.bounds.height, 0)
        isHidden = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LightView, _) in view.setNeedsLayout() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        quietly {
            let center = CGPoint(x: bounds.midX, y: bounds.maxY)
            grain.frame = bounds
            if grainTile.bounds.width > 0 {
                grainColumns.instanceCount = Int((bounds.width / grainTile.bounds.width).rounded(.up))
                grainRows.instanceCount = Int((bounds.height / grainTile.bounds.height).rounded(.up))
            }
            for sublayer in [risen, breath] {
                sublayer.bounds = bounds
                sublayer.position = sublayer === risen ? center : CGPoint(x: bounds.midX, y: bounds.maxY)
            }
            if !isLeaving {
                dome.bounds = CGRect(x: 0, y: 0, width: bounds.width * 1.9, height: domeHeight(level))
                dome.position = CGPoint(x: bounds.width * across, y: bounds.maxY)
            }
            crest.bounds = CGRect(x: 0, y: 0, width: bounds.width * 1.2, height: bounds.height * Self.crestDepth)
            crest.position.x = bounds.midX
        }
        drawIfNeeded()
        settle()
    }

    private func domeHeight(_ level: Double) -> Double {
        bounds.height * (Self.lowest + (Self.highest - Self.lowest) * level)
    }

    private static var pictures: [UIUserInterfaceStyle: LightPictures] = [:]

    /// Drawn away from the main thread, where it would hitch the card flying in.
    /// The light waits for them, or it would fade in with nothing to show.
    private func drawIfNeeded() {
        let style = traitCollection.userInterfaceStyle
        guard style != drawnStyle else { return }
        drawnStyle = style
        if let known = Self.pictures[style] {
            show(known)
            return
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Theme.accent).resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let accent = SIMD4<Float>(Float(red), Float(green), Float(blue), 1)
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                LightPictures(accent: accent, warms: style != .dark)
            }.value
            Self.pictures[style] = drawn
            if self?.drawnStyle == style { self?.show(drawn) }
        }
    }

    private func show(_ pictures: LightPictures) {
        quietly {
            dome.contents = pictures.dome
            crest.contents = pictures.crest
        }
        settle()
    }

    /// Brings the layers to what's wanted. Waits for a size, which comes after the first update.
    private func settle() {
        guard let wanted, !bounds.isEmpty, dome.contents != nil else { return }
        if wanted.isActive, !isLit {
            level = wanted.progress
            across = wanted.across
            strength = wanted.strength
            rise()
        } else if !wanted.isActive, isLit {
            if wanted.finished, !wanted.still { leaveUpward() } else { sink() }
        } else if wanted.isActive {
            if wanted.progress != level { climb(to: wanted.progress) }
            if wanted.across != across || wanted.strength != strength { glide() }
        }
    }

    // MARK: The light's movements

    private func rise() {
        generation += 1
        isLit = true
        isLeaving = false
        isHidden = false
        quietly {
            dome.removeAllAnimations()
            dome.bounds.size = CGSize(width: bounds.width * 1.9, height: domeHeight(level))
            dome.position.x = bounds.width * across
            dome.opacity = Float(0.8 + 0.2 * level)
            crest.opacity = 0
        }
        guard wanted?.still != true else {
            quietly {
                risen.transform = CATransform3DIdentity
                risen.opacity = Float(strength)
                grain.opacity = 1
            }
            return
        }
        let duration = wanted?.riseDuration ?? 0.7
        move(risen, "transform.scale.y", to: 1, from: risen.opacity > 0 ? nil : 0.6, duration: duration)
        move(risen, "opacity", to: strength, duration: duration)
        move(grain, "opacity", to: 1, duration: duration)
        if wanted?.breathes == true, breath.animation(forKey: "breathing") == nil { breathe() }
    }

    /// To a new place along the edge, or a new strength.
    private func glide() {
        guard let wanted else { return }
        across = wanted.across
        strength = wanted.strength
        guard !wanted.still else {
            quietly {
                dome.position.x = bounds.width * across
                risen.opacity = Float(strength)
            }
            return
        }
        move(dome, "position.x", to: bounds.width * across, duration: 0.9)
        move(risen, "opacity", to: strength, duration: 0.9)
    }

    /// Progress arrives in steps (a page read, then another). Each step is added on
    /// top of those still under way, so they blend into one continuous rise.
    private func climb(to target: Double) {
        let was = (from: domeHeight(level), opacity: 0.8 + 0.2 * level)
        level = target
        guard wanted?.still != true else {
            setNeedsLayout()
            return
        }
        let height = domeHeight(target), opacity = 0.8 + 0.2 * target
        quietly {
            dome.bounds.size.height = height
            dome.opacity = Float(opacity)
        }
        for (key, change) in [("bounds.size.height", was.from - height), ("opacity", was.opacity - opacity)] {
            let spring = CASpringAnimation(keyPath: key)
            spring.isAdditive = true
            spring.fromValue = change
            spring.toValue = 0.0
            spring.mass = 1
            spring.stiffness = 7
            spring.damping = 2 * 7.0.squareRoot()
            spring.duration = spring.settlingDuration
            spring.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            dome.add(spring, forKey: "\(key) \(generation) \(UUID())")
        }
    }

    private func breathe() {
        func swing(_ key: String, _ low: Double, _ high: Double) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = low
            animation.toValue = high
            return animation
        }
        let breathing = CAAnimationGroup()
        breathing.animations = [swing("transform.scale.x", 0.99, 1.02), swing("transform.scale.y", 0.97, 1.06),
                                swing("opacity", 0.84, 1)]
        breathing.duration = 3.2
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Slow and soft: a fast frame rate would spend power on a change nobody can see.
        breathing.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        // Or it's dropped for good the moment roko is in the background.
        breathing.isRemovedOnCompletion = false
        breath.add(breathing, forKey: "breathing")

        guard wanted?.drifts == true else { return }
        let drifting = CABasicAnimation(keyPath: "position.x")
        drifting.isAdditive = true
        drifting.fromValue = -bounds.width * 0.08
        drifting.toValue = bounds.width * 0.08
        drifting.duration = 7
        drifting.autoreverses = true
        drifting.repeatCount = .infinity
        drifting.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drifting.preferredFrameRateRange = breathing.preferredFrameRateRange
        drifting.isRemovedOnCompletion = false
        breath.add(drifting, forKey: "drifting")
    }

    /// Back into the edge it rose from.
    private func sink() {
        isLit = false
        guard wanted?.still != true else {
            move(risen, "opacity", to: 0, duration: 0.3)
            move(grain, "opacity", to: 0, duration: 0.3)
            hideAfter(0.3)
            return
        }
        move(risen, "transform.scale.y", to: 0.6, duration: 0.9)
        move(risen, "opacity", to: 0, duration: 0.9)
        move(grain, "opacity", to: 0, duration: 0.9)
        hideAfter(0.9)
    }

    /// The same light carrying on up: from wherever it has got to, its edge catches
    /// and the dome stretches after it, off the top of the screen, fading as it goes.
    private func leaveUpward() {
        isLit = false
        isLeaving = true
        let height = bounds.height
        let reached = (dome.presentation() ?? dome).bounds.height
        let lifted = (breath.presentation() ?? breath).value(forKeyPath: "transform.scale.y") as? Double ?? 1
        let start = height - reached * Self.edge * lifted
        // Far enough that the crest's tail has gone too.
        let end = -height * Self.crestDepth

        quietly {
            dome.removeAllAnimations()
            dome.bounds.size.height = reached
            crest.position.y = start
        }
        // Wider as it grows taller, or stretching turns the dome into a pillar.
        let growth = (height - end) / Self.edge / max(reached, 1)
        move(dome, "bounds.size.height", to: reached * growth, duration: Self.crossing, timing: Self.travel, fast: true)
        move(dome, "bounds.size.width", to: dome.bounds.width * growth, duration: Self.crossing, timing: Self.travel, fast: true)
        move(dome, "position.x", to: bounds.midX, duration: Self.crossing, timing: Self.travel, fast: true)
        move(crest, "position.y", to: end, from: start, duration: Self.crossing, timing: Self.travel, fast: true)

        // It catches quickly, holds while it crosses, and everything's gone by the end.
        quietly { crest.opacity = 0 }
        let catching = CAKeyframeAnimation(keyPath: "opacity")
        catching.values = [0, 1, 1, 0]
        catching.keyTimes = [0, 0.14, 0.5, 1]
        catching.duration = Self.sweepDuration
        catching.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        crest.add(catching, forKey: "catching")

        move(risen, "opacity", to: 0, duration: Self.sweepDuration - 0.1, delay: 0.1, fast: true)
        move(grain, "opacity", to: 0, duration: Self.sweepDuration - 0.1, delay: 0.1, fast: true)
        hideAfter(Self.sweepDuration)
    }

    private func hideAfter(_ seconds: TimeInterval) {
        generation += 1
        let leaving = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == leaving else { return }
            self.isLeaving = false
            self.breath.removeAllAnimations()
            self.isHidden = true
            self.quietly { self.risen.transform = CATransform3DIdentity }
            self.setNeedsLayout()
        }
    }

    /// From wherever it is now, so a movement can change its mind halfway.
    private func move(_ layer: CALayer, _ key: String, to value: Double, from start: Double? = nil, duration: TimeInterval,
                      delay: TimeInterval = 0, timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut),
                      fast: Bool = false) {
        let from = start ?? ((layer.presentation() ?? layer).value(forKeyPath: key) as? Double) ?? value
        layer.removeAnimation(forKey: key)
        quietly { layer.setValue(value, forKeyPath: key) }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        if fast { animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) }
        layer.add(animation, forKey: key)
    }

    private func quietly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// The light's two pictures, drawn once per appearance. They're small: everything in
/// them is soft, and at 16 bits a channel they stretch to the whole screen smoothly.
private nonisolated struct LightPictures: @unchecked Sendable {
    let dome: CGImage?, crest: CGImage?

    private typealias RGBA = SIMD4<Float>
    /// The warm end of the light's falloff on the light canvas.
    private static let amber = RGBA(0.96, 0.65, 0.14, 1)

    init(accent: SIMD4<Float>, warms: Bool) {
        dome = Self.dome(accent, warms: warms)
        crest = Self.crest(accent, warms: warms)
    }

    /// The top half of an ellipse centred on the bottom edge, as light coming from
    /// below the screen rather than a blob on it. Over the light canvas the accent's
    /// faint tail reads as pink, so there it warms toward amber as it falls off.
    /// Strong at the edge it rises from: at half strength over the near-black canvas,
    /// orange reads as rust, not light.
    private static func dome(_ accent: RGBA, warms: Bool) -> CGImage? {
        let stops: [(at: Float, strength: Float, warmth: Float)] = [
            (0, 0.85, 0), (0.16, 0.6, 0.25), (0.34, 0.38, 0.5), (0.52, 0.2, 0.65), (0.72, 0.08, 0.8), (1, 0, 0.8),
        ]
        return draw(width: 256, height: 128) { x, y in
            let across = (x - 0.5) * 2, up = 1 - y
            let distance = (across * across + up * up).squareRoot()
            guard distance < 1 else { return .zero }
            let next = stops.firstIndex { $0.at >= distance } ?? stops.count - 1
            let a = stops[max(next - 1, 0)], b = stops[next]
            let share = b.at > a.at ? (distance - a.at) / (b.at - a.at) : 0
            let warmth = warms ? a.warmth + (b.warmth - a.warmth) * share : 0
            let shade = accent + (amber - accent) * warmth
            return premultiplied(shade, a.strength + (b.strength - a.strength) * share)
        }
    }

    /// The bright edge: a tight lip, falling off fast ahead of it and slowly behind,
    /// never quite a straight line, so it reads as light and not as a ruled line.
    /// Warm white over the near-black canvas; over the light canvas white would read
    /// as a hole, so there it's the accent warmed.
    private static func crest(_ accent: RGBA, warms: Bool) -> CGImage? {
        let lip = warms ? accent + (amber - accent) * 0.3 : accent + (RGBA(1, 0.93, 0.82, 1) - accent) * 0.6
        let tail = warms ? accent + (amber - accent) * 0.75 : accent
        return draw(width: 256, height: 144) { x, y in
            let swell = sin(x * 3.1 + 0.7) * 0.016 + sin(x * 9.1 + 2.1) * 0.005
            let depth = (y - 0.1) * 0.56 - swell
            var strength = depth < 0 ? exp(-pow(depth / 0.03, 2)) : exp(-depth / 0.15)
            // Gone before the picture's own end, so that end never shows as an edge.
            let end = min(max((depth - 0.3) / 0.15, 0), 1)
            strength *= 1 - end * end * (3 - 2 * end)
            let inner = exp(-max(depth, 0) / 0.1)
            let body = tail + (accent - tail) * inner
            return premultiplied(body + (lip - body) * exp(-pow(depth / 0.022, 2)), strength * 0.85)
        }
    }

    private static func premultiplied(_ color: RGBA, _ alpha: Float) -> RGBA {
        RGBA(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
    }

    private static func draw(width: Int, height: Int, pixel: (_ x: Float, _ y: Float) -> RGBA) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let data = context.data
        else { return nil }
        for row in 0..<height {
            let line = (data + row * context.bytesPerRow).assumingMemoryBound(to: Float16.self)
            for column in 0..<width {
                let value = pixel((Float(column) + 0.5) / Float(width), (Float(row) + 0.5) / Float(height))
                for channel in 0..<4 { line[column * 4 + channel] = Float16(value[channel]) }
            }
        }
        return context.makeImage()
    }
}

/// A tile of fine monochrome noise, made once.
/// (Core Image made one in 90 ms, most of it setting up a CIContext: a hitch
/// the first time a light showed. This takes well under a millisecond.)
/// One noise dot per screen pixel, too fine and faint to read as static.
nonisolated enum Grain {
    /// Specks of faint white and black that need no blending and no mask, so it
    /// takes the GPU one plain pass: it dithers whatever is under it. Every row and
    /// column holds the same specks, shuffled. Plain random noise averages out a
    /// little differently per column, and repeated, that shows as a faint grid.
    static let dither: UIImage? = {
        let side = 192
        // From faint black to faint white, each as often as the others.
        let specks = (0..<side).map { Int8($0 % 5) - 2 }.shuffled()
        let rows = Array(0..<side).shuffled(), columns = Array(0..<side).shuffled()
        var pixels = [UInt8](repeating: 0, count: side * side * 2)
        for row in 0..<side {
            for column in 0..<side {
                let speck = specks[(rows[row] + columns[column]) % side]
                let index = (row * side + column) * 2
                pixels[index] = speck > 0 ? UInt8(speck) : 0
                pixels[index + 1] = UInt8(abs(speck))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: side * 2,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: 3, orientation: .up)
    }()
}
