import Foundation
import FoundationModels

/// Saved pages on one subject, put together so they can be summarized as one.
nonisolated struct ReadLaterGroup: Identifiable, Equatable, Codable {
    let name: String
    let pages: [UUID]
    var id: String { pages.map(\.uuidString).joined(separator: ",") }
}

/// Which unread pages belong together, judged by a language model from each
/// page's title, site and opening: Apple's models first (a small, private
/// job), Claude if neither is here. Sentence embeddings were tried first and
/// put an article on caffeine nearer one on embryo screening than one on
/// coffee. Pages that share a subject with nothing stay on their own.
///
/// Apple's small model, asked for groups, also makes one of two unrelated
/// pages ("Work and Wakefulness"), and asked for each page's subject, names
/// caffeine and coffee apart. Asked afterwards, a group at a time, whether its
/// pages belong together, it turns the made-up ones down: so each group it
/// proposes is checked before it's shown.
enum ReadLaterGroups {
    static func find(_ pages: [ReadLaterPage]) async -> [ReadLaterGroup] {
        guard pages.count >= 2 else { return [] }
        let numbered = pages.prefix(40)
        let prompt = numbered.enumerated().map { index, page in
            let opening = page.text.prefix(240).replacingOccurrences(of: "\n", with: " ")
            return "[\(index + 1)] \(page.title) (\(page.site)): \(opening)"
        }.joined(separator: "\n")
        var found: [(name: String, numbers: [Int])] = []
        do {
            if let cloud = AppleModels.cloudIfAvailable {
                found = try await withApple(cloud, prompt: prompt)
            } else if AppleModels.onDeviceAvailable {
                found = try await withApple(SystemLanguageModel.default, prompt: prompt)
            } else if let client = ClaudeClient.configured {
                found = try await withClaude(client, prompt: prompt)
            }
        } catch {
            // Apple's model declined or failed: Claude, if there's a key.
            AITrace.log("read later groups: \(error)")
            guard let client = ClaudeClient.configured, let retried = try? await withClaude(client, prompt: prompt) else { return [] }
            found = retried
        }
        // Each page in one group at most, and only groups of two or more.
        var taken = Set<Int>()
        return found.compactMap { group in
            let numbers = group.numbers.filter { numbered.indices.contains($0 - 1) && taken.insert($0).inserted }
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard numbers.count >= 2, !name.isEmpty else { return nil }
            return ReadLaterGroup(name: String(name.prefix(40)), pages: numbers.map { numbered[numbered.startIndex + $0 - 1].id })
        }
        .sorted { $0.pages.count > $1.pages.count }
    }

    private static let instructions = """
        You sort web pages someone saved to read later. Group pages that are about the same \
        subject, so they can be read together. A group has two or more pages; a page on a \
        subject no other page shares belongs to no group. Never put unrelated pages together \
        to make a group. Name each group in one to three words, in the pages' language, \
        capitalized like a title only at the first word.
        """

    private static func withApple(_ model: some LanguageModel, prompt: String) async throws -> [(name: String, numbers: [Int])] {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let proposed = try await session.respond(to: "Pages:\n" + prompt, generating: PageGroups.self).content.groups
        let lines = prompt.split(separator: "\n").map(String.init)
        var kept: [(name: String, numbers: [Int])] = []
        for group in proposed {
            let pages = group.pages.compactMap { lines.indices.contains($0 - 1) ? String(lines[$0 - 1].prefix(200)) : nil }
            guard pages.count >= 2 else { continue }
            let check = LanguageModelSession(model: model, instructions: """
                You check whether web pages belong together. Be strict: pages that only share a broad \
                area, such as health or work, do not.
                """)
            let verdict = try await check.respond(to: "Subject: \(group.name)\nPages:\n" + pages.joined(separator: "\n"),
                                                  generating: GroupCheck.self).content
            if verdict.together { kept.append((group.name, group.pages)) }
        }
        return kept
    }

    private static func withClaude(_ client: ClaudeClient, prompt: String) async throws -> [(name: String, numbers: [Int])] {
        var text = ""
        for try await event in client.stream(system: instructions + """
             Answer with one line a group, "<name> | <page numbers, comma separated>", and nothing \
            else; no lines at all if no two pages share a subject.
            """, prompt: "Pages:\n" + prompt, model: .haiku, effort: "low", maxTokens: 600) {
            if case .text(let chunk) = event { text += chunk }
        }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let numbers = parts[1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (String(parts[0]).trimmingCharacters(in: .whitespaces), numbers)
        }
    }
}

@Generable
nonisolated struct PageGroups {
    @Guide(description: "Groups of two or more pages about the same subject; none if no two pages share one", .count(0...8))
    var groups: [PageGroup]
}

@Generable
nonisolated struct PageGroup {
    @Guide(description: "The numbers of the pages in this group, as they are numbered in brackets", .count(2...12))
    var pages: [Int]
    @Guide(description: "The subject they share, one to three words")
    var name: String
}

@Generable
nonisolated struct GroupCheck {
    @Guide(description: "True only if every page is about the named subject and someone would want to read them together")
    var together: Bool
}
