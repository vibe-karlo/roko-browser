import Foundation

/// Milliseconds since this process started, for launch timing.
enum LaunchClock {
    static var elapsed: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_starttime
        let startMs = Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
        return Date().timeIntervalSince1970 * 1000 - startMs
    }

    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-perf")

    static func mark(_ label: String) {
        guard isEnabled else { return }
        print(String(format: "PERF %@ %.0fms", label, elapsed))
    }
}
