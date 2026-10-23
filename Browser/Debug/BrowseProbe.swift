import Foundation

#if DEBUG
/// Runs Browse for Me on launch and prints a timeline, so its speed can be
/// measured on a real phone over the cable, with the phone's own key and network:
///
///     xcrun devicectl device process launch --console --device <id> \
///         com.growthstudio.roko -perf -browse "first question" -browse "second"
///
/// Each line is seconds since that question started. ClaudeClient adds the
/// request, search and token lines when -perf is on.
enum BrowseProbe {
    static var questions: [String] {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.indices.dropLast().filter { arguments[$0] == "-browse" }.map { arguments[$0 + 1] }
    }

    static func run() async {
        for question in questions {
            AITrace.start("BROWSE \"\(question)\"")
            let model = BrowseForMeModel(query: question)
            AITrace.log("depth \(model.depth)")
            let watch = Task { await watchPhases(of: model) }
            await model.run()
            watch.cancel()
            AITrace.log("done: \(model.phase) engine=\(model.engine) sources=\(model.sources.count) chars=\(model.text.count)")
            print("PROBE answer >>>\n\(model.text)\n<<<")
        }
        print("PROBE finished")
    }

    /// Notes each phase change (searching, reading, writing) as it happens.
    private static func watchPhases(of model: BrowseForMeModel) async {
        var last = ""
        while !Task.isCancelled {
            let now = "\(model.phase)"
            if now != last {
                AITrace.log("phase \(now)")
                last = now
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif

/// Timestamped lines for measuring the AI features, printed only with -perf.
enum AITrace {
    nonisolated(unsafe) private static var started = Date()

    static func start(_ label: String) {
        guard LaunchClock.isEnabled else { return }
        started = Date()
        print("AI 0.00s \(label)")
    }

    static func log(_ line: @autoclosure () -> String) {
        guard LaunchClock.isEnabled else { return }
        print(String(format: "AI %.2fs ", Date().timeIntervalSince(started)) + line())
    }
}
