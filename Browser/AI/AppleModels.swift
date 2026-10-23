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
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
    @Guide(description: "Three to five sections, each about a different aspect", .count(3...5))
    var sections: [GeneratedSection]
}

@Generable
nonisolated struct GeneratedSection {
    @Guide(description: "The topic that best fits this section, used for its icon", .anyOf(AnswerTopic.all))
    var topic: String
    @Guide(description: "A heading of two to four words, written for this answer")
    var heading: String
    @Guide(description: "Two to four short points, one sentence each; start with a key term in **bold** when there is one", .count(2...4))
    var points: [String]
}

/// The short shape, for a quick question: the answer itself, and a few
/// supporting points if they help. No sections to fill.
@Generable
nonisolated struct BriefAnswer {
    @Guide(description: "A specific title for the answer, a few words")
    var title: String
    @Guide(description: "The direct answer in one to three plain sentences")
    var answer: String
    @Guide(description: "Up to three short supporting points, one sentence each; start with a key term in **bold** when there is one", .count(0...3))
    var points: [String]
}

/// A partly written answer, shown as the app's Markdown while it streams.
nonisolated protocol AnswerDraft {
    /// `droppingUnfinished` leaves out the last point, which may have been cut off.
    func markdown(titled: Bool, droppingUnfinished: Bool) -> String
    /// Whether enough is written to be worth showing if generation stops here.
    var isUseful: Bool { get }
}

extension GeneratedAnswer.PartiallyGenerated: AnswerDraft {
    var isUseful: Bool { sections?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        var sections = self.sections ?? []
        if droppingUnfinished, var last = sections.popLast() {
            last.points = Array((last.points ?? []).dropLast())
            if last.points?.isEmpty == false { sections.append(last) }
        }
        var lines: [String] = []
        if titled, let title, !title.isEmpty { lines.append("# \(title)") }
        if let gist, !gist.isEmpty { lines.append("> \(gist)") }
        for section in sections {
            guard let heading = section.heading, !heading.isEmpty else { continue }
            lines.append("## [\(section.topic ?? "")] \(heading)")
            for point in section.points ?? [] where !point.isEmpty { lines.append("- \(point)") }
        }
        return lines.joined(separator: "\n")
    }
}

extension BriefAnswer.PartiallyGenerated: AnswerDraft {
    /// Once a point has begun, the answer before it is whole.
    var isUseful: Bool { points?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        var lines: [String] = []
        if titled, let title, !title.isEmpty { lines.append("# \(title)") }
        if let answer, !answer.isEmpty { lines.append("> \(answer)") }
        let points = droppingUnfinished ? Array((self.points ?? []).dropLast()) : self.points ?? []
        for point in points where !point.isEmpty { lines.append("- \(point)") }
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
            let task = Task {
                var latest: Answer.PartiallyGenerated?
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt, generating: Answer.self) {
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
