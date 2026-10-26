import Foundation

/// Per-site page zoom, in the same steps Safari uses.
enum PageZoom {
    static let levels: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func level(for host: String?) -> CGFloat {
        guard let host else { return 1 }
        let stored = UserDefaults.standard.double(forKey: key(host))
        return stored > 0 ? stored : 1
    }

    static func remember(_ level: CGFloat, for host: String?) {
        guard let host else { return }
        if level == 1 {
            UserDefaults.standard.removeObject(forKey: key(host))
        } else {
            UserDefaults.standard.set(Double(level), forKey: key(host))
        }
    }

    static func step(from current: CGFloat, direction: Int) -> CGFloat {
        if direction > 0 { return levels.first { $0 > current + 0.001 } ?? levels.last! }
        return levels.last { $0 < current - 0.001 } ?? levels.first!
    }

    /// Every site zoomed away from 100%: for Settings → Sites.
    static func all() -> [String: CGFloat] {
        UserDefaults.standard.dictionaryRepresentation().reduce(into: [:]) { sites, entry in
            if entry.key.hasPrefix("zoom."), let level = entry.value as? Double { sites[String(entry.key.dropFirst(5))] = level }
        }
    }

    static func forget(_ host: String) {
        UserDefaults.standard.removeObject(forKey: key(host))
    }

    private static func key(_ host: String) -> String {
        "zoom." + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }
}
