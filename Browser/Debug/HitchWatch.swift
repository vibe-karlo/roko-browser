import QuartzCore
import UIKit

/// With -perf: logs every frame that takes longer than 40 ms for a few
/// seconds, with the time since `start`, to find what stalls an animation.
@MainActor
final class HitchWatch: NSObject {
    private static var current: HitchWatch?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let began = CACurrentMediaTime()

    static func start(_ label: String, for seconds: Double = 2) {
        guard LaunchClock.isEnabled else { return }
        current?.link?.invalidate()
        let watch = HitchWatch()
        current = watch
        print("HITCH watch \(label)")
        let link = CADisplayLink(target: watch, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        watch.link = link
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { link.invalidate() }
    }

    static func note(_ label: String) {
        guard LaunchClock.isEnabled, let current else { return }
        print(String(format: "HITCH %@ at %.0fms", label, (CACurrentMediaTime() - current.began) * 1000))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0, now - last > 0.04 {
            print(String(format: "HITCH frame %.0fms at %.0fms", (now - last) * 1000, (now - began) * 1000))
        }
        last = now
    }
}
