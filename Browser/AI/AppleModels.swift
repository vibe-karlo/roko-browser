import Foundation
import FoundationModels

/// Apple's two models. The cloud one (Private Cloud Compute) is larger and
/// writes better answers, stays private, needs no key, and is rate-limited per
/// device by Apple. The on-device one is the always-there fallback.
enum AppleModels {
    static let cloud = PrivateCloudComputeLanguageModel()

    /// Apple grants Private Cloud Compute as a managed entitlement, and without
    /// it FoundationModels traps rather than throwing (even though isAvailable
    /// says true). So the cloud model is only used in builds that declare the
    /// entitlement, marked by the PRIVATE_CLOUD_COMPUTE flag (see project.yml).
    static var cloudIfAvailable: PrivateCloudComputeLanguageModel? {
        #if PRIVATE_CLOUD_COMPUTE
        cloud.isAvailable ? cloud : nil
        #else
        nil
        #endif
    }

    static var onDeviceAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// The on-device model with the guardrails Apple provides for transforming
    /// text the user already has, such as summarizing an article: a news story
    /// about a crime is the page's content, not a request for harm, and the
    /// default guardrails turn many of those down.
    static let summarizing = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// Roughly how many characters fit in a model's context, leaving room for
    /// instructions and the answer. About three characters per token.
    static func characterBudget(of model: PrivateCloudComputeLanguageModel, reservingTokens: Int = 2_500) async -> Int {
        budget(tokens: (try? await model.contextSize) ?? 4_096, reserving: reservingTokens)
    }

    static func onDeviceCharacterBudget(reservingTokens: Int = 1_500) -> Int {
        budget(tokens: SystemLanguageModel.default.contextSize, reserving: reservingTokens)
    }

    private static func budget(tokens: Int, reserving: Int) -> Int {
        max(1_500, (tokens - reserving) * 3)
    }

    /// Streams the growing answer text.
    static func stream(_ model: some LanguageModel, instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let heartbeat = Heartbeat()
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        heartbeat.last = .now
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watch = watchForQuiet(heartbeat, task: task, continuation: continuation)
            continuation.onTermination = { _ in task.cancel(); watch.cancel() }
        }
    }

    // MARK: Going quiet

    /// A model can go quiet without failing: no first words, nothing more, and
    /// no error either. Browse for Me sat on "Writing your answer" for minutes
    /// that way. This long without a word counts as failed.
    static var quietLimit: Duration {
        #if DEBUG
        // `-quietLimit 1` to see what happens when the model goes quiet.
        let seconds = UserDefaults.standard.double(forKey: "quietLimit")
        if seconds > 0 { return .seconds(seconds) }
        #endif
        return .seconds(30)
    }

    /// The model said nothing for `quietLimit`.
    struct WentQuiet: LocalizedError {
        var errorDescription: String? { "Apple's on-device model stopped answering." }
    }

    /// When the model last wrote something (or was asked).
    final class Heartbeat {
        var last = ContinuousClock.now
    }

    /// Ends the stream with `WentQuiet` once nothing has come for `quietLimit`.
    static func watchForQuiet<Output: Sendable>(_ heartbeat: Heartbeat, task: Task<Void, Never>,
                                                continuation: AsyncThrowingStream<Output, Error>.Continuation) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if ContinuousClock.now - heartbeat.last > quietLimit {
                    task.cancel()
                    continuation.finish(throwing: WentQuiet())
                    return
                }
            }
        }
    }

    /// What to say when Apple's model fails, in place of the framework's own
    /// words ("The model refused to answer."). Nil for failures it can't explain.
    static func explain(_ error: Error, doing: String) -> String? {
        let claude = ClaudeClient.configured == nil ? " With a Claude API key in Settings, Claude takes over when this happens." : ""
        if error is WentQuiet {
            return "Apple's on-device model stopped before it could \(doing). Try again in a moment."
        }
        guard let error = error as? LanguageModelError else { return nil }
        switch error {
        case .guardrailViolation, .refusal:
            return "Apple's on-device model declined to \(doing).\(claude)"
        case .contextSizeExceeded:
            return "There was too much to read at once for Apple's on-device model.\(claude)"
        case .rateLimited, .timeout:
            return "Apple's on-device model is busy. Try again in a moment."
        case .unsupportedLanguageOrLocale:
            return "Apple's on-device model doesn't write this language yet.\(claude)"
        default:
            return nil
        }
    }
}

/// The answer shape for Apple's models, enforced by guided generation: the
/// model fills these fields rather than being asked to follow a text format,
/// which the small on-device model doesn't reliably do.
@Generable
nonisolated struct GeneratedAnswer {
    @Guide(description: "A specific title for the answer, a few words")
    var title: String
    @Guide(description: "The gist in one or two plain sentences")
    var gist: String
    @Guide(description: "Three more facts most worth knowing, not the gist again, one short sentence each, at most 15 words", .count(3))
    var keyPoints: [String]
    @Guide(description: "Two to four sections with the details, each about a different aspect", .count(2...4))
    var sections: [GeneratedSection]
}

@Generable
nonisolated struct GeneratedSection {
    @Guide(description: "What this section is about, for its icon: food for restaurants and dishes, weather for climate and seasons, money for prices, place for locations, and so on",
           .anyOf(AnswerTopic.all))
    var topic: String
    @Guide(description: "A heading of two to four words, written for this answer")
    var heading: String
    @Guide(description: "Two to four short points, one sentence each, at most 20 words; start with a key term in **bold** when there is one", .count(2...4))
    var points: [String]
}

/// One option to choose, for an answer about which to pick.
@Generable
nonisolated struct GeneratedPick {
    @Guide(description: "The option's name, as the sources write it")
    var name: String
    @Guide(description: "Its price or deciding number from the sources, as short as $299 or 40 hours; an empty string if the sources give none")
    var figure: String
    @Guide(description: "Who or what it suits best, three to six words")
    var suits: String
}

/// The short shape, for a quick question: the answer itself, and a few
/// supporting points if they help. No sections to fill.
@Generable
nonisolated struct BriefAnswer {
    @Guide(description: "A specific title for the answer, a few words")
    var title: String
    @Guide(description: "The direct answer in one to three plain sentences")
    var answer: String
    @Guide(description: "Up to three short supporting facts, each a full sentence with a number, name or detail; bold only a key term at its start, if there is one", .count(0...3))
    var points: [String]
    @Guide(description: followUpsGuide, .count(0...3))
    var followUps: [String]
}

/// Browse for Me's shape for a question worth sections: GeneratedAnswer's,
/// plus questions to ask next. (Summaries keep GeneratedAnswer: nobody asks a
/// page a follow-up.)
@Generable
nonisolated struct ResearchedAnswer {
    @Guide(description: "A specific title for the answer, a few words")
    var title: String
    @Guide(description: "The gist in one or two plain sentences")
    var gist: String
    // First, so the verdict is the first thing written and read.
    @Guide(description: "Only when the question asks which to choose or what is best: the two to four top options, best first. Otherwise none", .count(0...4))
    var picks: [GeneratedPick]
    // Made to write at least three, the small model padded thin sources with
    // sections on what they don't say ("prices are not specified").
    @Guide(description: "Two to five sections, each about a different aspect the sources cover", .count(2...5))
    var sections: [GeneratedSection]
    @Guide(description: followUpsGuide, .count(0...3))
    var followUps: [String]
}

private nonisolated let followUpsGuide =
    "Up to three short follow-up questions the person is likely to ask next, in the language of the answer; none if they wouldn't help"

/// A partly written answer, shown as the app's Markdown while it streams.
/// More of a summary, from a later part of the page: sections only, to add
/// below what's already there.
@Generable
nonisolated struct FurtherSections {
    @Guide(description: "One or two sections on what this part adds, each about a different aspect", .count(1...2))
    var sections: [GeneratedSection]
}

extension FurtherSections.PartiallyGenerated: AnswerDraft {
    var isUseful: Bool { sections?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        sectionedMarkdown(title: nil, gist: nil, sections: sections ?? [], followUps: [], droppingUnfinished: droppingUnfinished)
    }
}

nonisolated protocol AnswerDraft {
    /// `droppingUnfinished` leaves out the last point, which may have been cut off.
    func markdown(titled: Bool, droppingUnfinished: Bool) -> String
    /// Whether enough is written to be worth showing if generation stops here.
    var isUseful: Bool { get }
}

extension GeneratedAnswer.PartiallyGenerated: AnswerDraft {
    var isUseful: Bool { sections?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        sectionedMarkdown(title: titled ? title : nil, gist: gist, keyPoints: keyPoints ?? [], sections: sections ?? [],
                          followUps: [], droppingUnfinished: droppingUnfinished)
    }
}

extension ResearchedAnswer.PartiallyGenerated: AnswerDraft {
    var isUseful: Bool { sections?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        sectionedMarkdown(title: titled ? title : nil, gist: gist, picks: picks ?? [], sections: sections ?? [],
                          followUps: followUps ?? [], droppingUnfinished: droppingUnfinished)
    }
}

/// Title, gist and sections, then any follow-ups as "?? " lines (Browse for Me
/// lifts those out of the answer). Cut off mid-way, the last item is dropped:
/// a follow-up if they had begun, otherwise a point.
private nonisolated func sectionedMarkdown(title: String?, gist: String?, keyPoints: [String] = [],
                                           picks: [GeneratedPick.PartiallyGenerated] = [],
                                           sections: [GeneratedSection.PartiallyGenerated],
                                           followUps: [String], droppingUnfinished: Bool) -> String {
    var sections = sections, followUps = followUps
    if droppingUnfinished {
        if !followUps.isEmpty {
            followUps.removeLast()
        } else if var last = sections.popLast() {
            last.points = Array((last.points ?? []).dropLast())
            if last.points?.isEmpty == false { sections.append(last) }
        }
    }
    var lines: [String] = []
    if let title, !title.isEmpty { lines.append("# \(title)") }
    if let gist, !gist.isEmpty { lines.append("> \(gist)") }
    for point in keyPoints where !point.isEmpty { lines.append("> - \(point)") }
    for pick in picks {
        guard let name = pick.name, !name.isEmpty else { continue }
        lines.append("=> \(name) | \(pick.figure ?? "") | \(pick.suits ?? "")")
    }
    for section in sections {
        guard let heading = section.heading, !heading.isEmpty else { continue }
        lines.append("## [\(section.topic ?? "")] \(heading)")
        for point in section.points ?? [] where !point.isEmpty { lines.append("- \(point)") }
    }
    for question in followUps where !question.isEmpty { lines.append("?? \(question)") }
    return lines.joined(separator: "\n")
}

extension BriefAnswer.PartiallyGenerated: AnswerDraft {
    /// Once a point has begun, the answer before it is whole.
    var isUseful: Bool { points?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        var lines: [String] = []
        if titled, let title, !title.isEmpty { lines.append("# \(title)") }
        if let answer, !answer.isEmpty { lines.append("> \(answer)") }
        var points = self.points ?? [], followUps = self.followUps ?? []
        if droppingUnfinished {
            if !followUps.isEmpty { followUps.removeLast() } else if !points.isEmpty { points.removeLast() }
        }
        for point in points where !point.isEmpty { lines.append("- \(point)") }
        for question in followUps where !question.isEmpty { lines.append("?? \(question)") }
        return lines.joined(separator: "\n")
    }
}

extension AppleModels {
    /// Streams a structured answer, as Markdown the app's renderer lays out.
    /// `titled` false leaves the title out (a page summary has the page's own).
    static func streamAnswer<Answer: Generable>(_ model: some LanguageModel, shape: Answer.Type = GeneratedAnswer.self,
                                                instructions: String, prompt: String,
                                                titled: Bool = true) -> AsyncThrowingStream<String, Error>
    where Answer.PartiallyGenerated: AnswerDraft {
        AsyncThrowingStream { continuation in
            let heartbeat = Heartbeat()
            let task = Task {
                var latest: Answer.PartiallyGenerated?
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt, generating: Answer.self) {
                        heartbeat.last = .now
                        latest = snapshot.content
                        continuation.yield(snapshot.content.markdown(titled: titled, droppingUnfinished: false))
                    }
                    continuation.finish()
                } catch LanguageModelError.contextSizeExceeded where latest?.isUseful == true {
                    // The model ran on until its context was full, usually by
                    // repeating itself. Keep everything it finished and drop
                    // only the point it was cut off in: no answer ends mid-word.
                    continuation.yield(latest!.markdown(titled: titled, droppingUnfinished: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watch = watchForQuiet(heartbeat, task: task, continuation: continuation)
            continuation.onTermination = { _ in task.cancel(); watch.cancel() }
        }
    }
}
