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

extension AppleModels {
    /// Streams a structured answer, as Markdown the app's renderer lays out.
    /// `titled` false leaves the title out (a page summary has the page's own).
    static func streamAnswer(_ model: some LanguageModel, instructions: String, prompt: String,
                             titled: Bool = true) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt, generating: GeneratedAnswer.self) {
                        continuation.yield(markdown(snapshot.content, titled: titled))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func markdown(_ answer: GeneratedAnswer.PartiallyGenerated, titled: Bool) -> String {
        var lines: [String] = []
        if titled, let title = answer.title, !title.isEmpty { lines.append("# \(title)") }
        if let gist = answer.gist, !gist.isEmpty { lines.append("> \(gist)") }
        for section in answer.sections ?? [] {
            guard let heading = section.heading, !heading.isEmpty else { continue }
            lines.append("## [\(section.topic ?? "")] \(heading)")
            for point in section.points ?? [] where !point.isEmpty { lines.append("- \(point)") }
        }
        return lines.joined(separator: "\n")
    }
}
