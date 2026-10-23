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
