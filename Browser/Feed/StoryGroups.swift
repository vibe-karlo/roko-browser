import Foundation
import FoundationModels

/// Stories from different sites about one event, so it's read once. Found in
/// two steps: their headlines' rarer words put candidates together, then a
/// language model checks each candidate, a group at a time. Headlines stay in
/// the sites' own words, as in Today.
nonisolated enum StoryGroups {
    /// Stories sharing what's rare in the day's headlines, oldest first: words
    /// every other headline has ("Hrvatska") say little. A story joins a group
    /// when it matches at least half of it, not any one story: matched against
    /// any one, "Hajduk" gathered a report, a poll and an explainer into one,
    /// and a chess item joined a group through a single word. Tried on a day's
    /// 370 Croatian and 125 English headlines. Only groups spanning two sites.
    static func candidates(_ stories: [NewsStory]) -> [[NewsStory]] {
        let oldestFirst = stories.sorted { ($0.published ?? .now) < ($1.published ?? .now) }
        let stems = oldestFirst.map { TodayNews.stems($0.title) }
        let names = oldestFirst.map { Self.names(in: $0.title) }
        let starts = oldestFirst.map { Set(TodayNews.words(of: $0.title).map { String($0.prefix(4)) }) }
        var frequency: [String: Int] = [:]
        for words in stems { for word in words { frequency[word, default: 0] += 1 } }
        let total = Double(oldestFirst.count + 1)
        func weight(_ words: Set<String>) -> Double {
            words.reduce(0) { $0 + log(total / Double(frequency[$1] ?? 1)) }
        }
        func score(_ i: Int, _ j: Int) -> Double {
            let a = stems[i], b = stems[j]
            let shared = a.intersection(b)
            guard shared.count >= 2 else { return 0 }
            // "Što Hajduku treba za prolaz" and "Što Dinamu treba za prolaz" share all
            // but who it's about, and the model passed them as one event: each
            // names someone, and neither name is anywhere in the other.
            if !names[i].isEmpty, !names[j].isEmpty, names[i].isDisjoint(with: starts[j]), names[j].isDisjoint(with: starts[i]) { return 0 }
            return weight(shared) / min(weight(a), weight(b))
        }
        var groups: [[Int]] = []
        for index in oldestFirst.indices {
            var best: Int?
            var bestScore = 0.0
            for (number, group) in groups.enumerated() {
                let scores = group.map { score(index, $0) }
                let matches = scores.filter { $0 >= 0.5 }.count
                if matches * 2 >= group.count, let top = scores.max(), top > bestScore {
                    best = number
                    bestScore = top
                }
            }
            if let best { groups[best].append(index) } else { groups.append([index]) }
        }
        return groups.map { $0.map { oldestFirst[$0] } }.filter(spansSites)
    }

    /// The capitalized words past the first, cut short so "Hajduku" meets
    /// "Hajduka". Nothing for a headline in title case: there every word has a capital.
    private static func names(in title: String) -> Set<String> {
        let words = title.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.dropFirst().filter { $0.count >= 4 }
        let capitalized = words.filter { $0.first?.isUppercase == true }
        guard capitalized.count * 2 <= words.count else { return [] }
        return Set(capitalized.flatMap { TodayNews.words(of: $0) }.map { String($0.prefix(4)) })
    }

    static func spansSites(_ stories: [NewsStory]) -> Bool {
        Set(stories.map(\.host)).count >= 2
    }

    /// The headline to show for a group: the fullest that still reads as one line of news.
    static func title(of stories: [NewsStory]) -> String {
        let titles = stories.map(\.title)
        return titles.filter { $0.count <= 120 }.max { $0.count < $1.count } ?? titles.min { $0.count < $1.count } ?? ""
    }

    // MARK: Checking

    /// A model is here to check groups with.
    @MainActor static var canConfirm: Bool {
        AppleModels.onDeviceAvailable || ClaudeClient.configured != nil
    }

    private static let instructions = """
        You sort news headlines. Headline 1 reports one event. Find the other headlines reporting that \
        same event, in any words. Someone else's reaction to it, a poll, a quiz, a profile or a background \
        piece is not the same event. Neither is an earlier or later event involving the same people.
        """

    /// The stories that are really about the first one's event. All of them
    /// when the model can't say (it declines some headlines about crime).
    @MainActor static func confirm(_ stories: [NewsStory]) async -> [NewsStory] {
        let numbered = stories.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        var numbers: [Int]?
        if AppleModels.onDeviceAvailable {
            let session = LanguageModelSession(model: AppleModels.summarizing, instructions: instructions)
            numbers = try? await session.respond(to: "Headlines:\n" + numbered, generating: SameEvent.self).content.numbers
        }
        if numbers == nil, let client = ClaudeClient.configured {
            numbers = try? await withClaude(client, numbered)
        }
        guard let numbers else { return stories }
        let kept = Set(numbers).union([1])
        return stories.enumerated().filter { kept.contains($0.offset + 1) }.map(\.element)
    }

    @MainActor private static func withClaude(_ client: ClaudeClient, _ numbered: String) async throws -> [Int] {
        var text = ""
        for try await event in client.stream(system: instructions + " Answer with their numbers, comma separated, and nothing else.",
                                             prompt: "Headlines:\n" + numbered, model: .haiku, effort: "low", maxTokens: 100) {
            if case .text(let chunk) = event { text += chunk }
        }
        return text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

@Generable
nonisolated struct SameEvent {
    @Guide(description: "The numbers of the headlines reporting the same event as headline 1, including 1")
    var numbers: [Int]
}
