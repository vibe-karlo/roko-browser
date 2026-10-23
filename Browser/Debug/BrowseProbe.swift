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

    /// Follow-ups to ask on the last question's page: `-then "and in winter?"`.
    static var followUps: [String] {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.indices.dropLast().filter { arguments[$0] == "-then" }.map { arguments[$0 + 1] }
    }

    static func run() async {
        var last: BrowseForMeModel?
        for question in questions {
            let model = BrowseForMeModel(query: question)
            await measure(model)
            last = model
        }
        // Follow-ups carry the page so far, as BrowseSession.ask does.
        var context = last.map { [(question: $0.query, answer: $0.answer)] } ?? []
        for question in followUps {
            let model = BrowseForMeModel(query: question, context: context)
            await measure(model)
            context.append((question: model.query, answer: model.answer))
        }
        print("PROBE finished")
    }

    private static func measure(_ model: BrowseForMeModel) async {
        AITrace.start("BROWSE \"\(model.query)\" context=\(model.context.count)")
        AITrace.log("depth \(model.depth)")
        let watch = Task { await watchPhases(of: model) }
        await model.run()
        watch.cancel()
        AITrace.log("answered; pictures=\(model.images.count) pending=\(model.pendingPictures)")
        // Pictures are looked for alongside; note when the last one lands.
        for _ in 0..<60 where model.pendingPictures > 0 { try? await Task.sleep(for: .milliseconds(100)) }
        AITrace.log("done: \(model.phase) engine=\(model.engine) sources=\(model.sources.count) pictures=\(model.images.count) chars=\(model.text.count)")
        print("PROBE answer >>>\n\(model.text)\n<<<")
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
