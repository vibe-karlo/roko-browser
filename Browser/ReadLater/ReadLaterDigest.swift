import FoundationModels
import UIKit

/// "Summarize all": one summary across every unread saved page, grouped by
/// theme rather than page by page, each point marked with the pages it comes
/// from ("[[2]]"), which open them. Written from the text kept at save time,
/// so it works offline and on pages that have since changed. Apple's cloud
/// model first, then Claude, then the on-device model; a language Apple's
/// models write badly goes to Claude first, as for a single page.
@Observable
final class DigestModel: Identifiable {
    enum Phase: Equatable {
        case reading, writing, done, failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// The pages it's written from, in the order of their marks: [[1]] is the first.
    let pages: [ReadLaterPage]
    /// The group's name, for a group's summary; nil for all of them.
    let subject: String?
    private(set) var text = ""
    private(set) var phase: Phase = .reading
    private(set) var engine = ""
    private(set) var note: String?

    init(pages: [ReadLaterPage], subject: String? = nil) {
        self.pages = pages
        self.subject = subject
    }

    var isWorking: Bool {
        phase == .reading || phase == .writing && text.isEmpty
    }

    var progress: Double {
        switch phase {
        case .reading: 0.2 + 0.5 * Double(condensed) / Double(max(pages.count, 1))
        default: 0.8
        }
    }

    /// Pages read down to their main points so far, when they don't all fit at once.
    private(set) var condensed = 0

    /// "4 pages, 38 min read → 2 min".
    var readingTime: String? {
        guard phase == .done else { return nil }
        let minutes = pages.map(\.minutes).reduce(0, +)
        let seconds = max(10, Int((Double(SavedStats.words(in: text)) / 230 * 60 / 10).rounded()) * 10)
        return "\(minutes) min read → \(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min")"
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        if let kept = ReadLater.shared.digest(for: pages) {
            text = kept.text
            engine = kept.engine
            note = kept.note
            phase = .done
            return
        }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    /// Writes it afresh, after a failure.
    func retry() {
        guard phase.isFailure else { return }
        text = ""
        note = nil
        condensed = 0
        phase = .reading
        task = Task { await run() }
    }

    // MARK: Writing

    private enum Engine { case appleCloud, claude, onDevice }

    private func run() async {
        let readable = pages.filter { $0.text.count > 200 }
        guard !readable.isEmpty else {
            phase = .failed("None of these pages had text to read when they were saved.")
            return
        }
        let sample = readable.map { "\($0.title)\n\($0.text.prefix(600))" }.joined(separator: "\n\n")
        let language = await Task.detached(priority: .userInitiated) { AnswerLanguage.target(for: sample) }.value
        let appleWritesIt = language?.appleWritesWell ?? true
        var engines: [Engine] = [.appleCloud, .onDevice]
        if ClaudeClient.configured != nil { engines.insert(.claude, at: appleWritesIt ? 1 : 0) }
        #if DEBUG
        // `-digestEngine onDevice`: only the on-device model, to see how it does.
        if UserDefaults.standard.string(forKey: "digestEngine") == "onDevice" { engines = [.onDevice] }
        #endif

        var lastError: Error = ClaudeError(
            message: "Summaries need Apple Intelligence on this iPhone, or a Claude API key in Settings.")
        for engine in engines {
            do {
                guard try await write(with: engine, language: language, appleWritesIt: appleWritesIt) else { continue }
                text = Self.keepingMarks(text, upTo: pages.count)
                phase = .done
                SavedStats.summary(pageWords: pages.map(\.words).reduce(0, +), summaryWords: SavedStats.words(in: text))
                ReadLater.shared.keep(.init(pageIDs: pages.map(\.id), text: text, engine: self.engine, note: note, at: .now))
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                AITrace.log("digest: \(self.engine) failed: \(error)")
                lastError = error
                text = ""
                note = nil
                condensed = 0
                phase = .reading
            }
        }
        phase = .failed(AppleModels.explain(lastError, doing: "summarize these pages") ?? lastError.localizedDescription)
    }

    /// One engine's go; false when it isn't available here.
    private func write(with engine: Engine, language: WritingLanguage?, appleWritesIt: Bool) async throws -> Bool {
        let appleLanguage = appleWritesIt ? language : .english
        let languageNote = appleWritesIt ? nil : language.map { "In English: Apple's models write poor \($0.english)." }
        switch engine {
        case .appleCloud:
            guard let cloud = AppleModels.cloudIfAvailable else { return false }
            self.engine = "Apple Intelligence"
            let budget = await AppleModels.characterBudget(of: cloud, reservingTokens: 3_000)
            try await writeWithApple(cloud, budget: budget, language: appleLanguage, languageNote: languageNote)

        case .onDevice:
            guard AppleModels.onDeviceAvailable else { return false }
            self.engine = "On-device"
            try await writeWithApple(AppleModels.summarizing, budget: AppleModels.onDeviceCharacterBudget(reservingTokens: 1_800),
                                     language: appleLanguage, languageNote: languageNote)

        case .claude:
            guard let client = ClaudeClient.configured else { return false }
            self.engine = "Claude"
            // Haiku reads a lot for little: 150,000 characters shared out,
            // each page shortened to its share when they come to more.
            let (prompt, shortened) = Self.prompt(pages, budget: 150_000)
            note = Self.note(shortened ? "Long pages: their first parts." : nil)
            phase = .writing
            do {
                try await stream(client, prompt: prompt, model: .haiku, language: language)
            } catch let error as ClaudeError where error.isRefusal {
                text = ""
                try await stream(client, prompt: prompt, model: .sonnet, language: language)
            }
        }
        try Task.checkCancellation()
        return true
    }

    /// Apple's models, guided into the digest's shape. When every page fits in
    /// the model's budget at a useful length, in one pass; otherwise each page
    /// is first read down to its main points with the same model, a page at a
    /// time, and the digest is written from those.
    private func writeWithApple(_ model: some LanguageModel, budget: Int, language: WritingLanguage?,
                                languageNote: String?) async throws {
        let readable = pages.enumerated().filter { $0.element.text.count > 200 }
        let share = budget / max(readable.count, 1)
        var prompt: String
        var shortened = false
        if share >= 1_800 {
            (prompt, shortened) = Self.prompt(pages, budget: budget)
        } else {
            // Each page's points from as much of it as the model reads at once.
            let perPage = max(1_500, budget - 400)
            var notes: [(Int, String)] = []
            for (index, page) in readable {
                try Task.checkCancellation()
                if page.text.count > perPage { shortened = true }
                let session = LanguageModelSession(model: model, instructions: Self.condensing)
                let points = try await session.respond(to: "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text.prefix(perPage))",
                                                       generating: PageNotes.self).content.points
                notes.append((index + 1, points.map { "- \($0)" }.joined(separator: "\n")))
                condensed += 1
            }
            prompt = Self.prompt(notes.map { number, points in (number, pages[number - 1], points) }, budget: budget)
        }
        note = Self.note(shortened ? "Long pages: their first parts." : nil, languageNote)
        phase = .writing
        let stream = AppleModels.streamAnswer(model, shape: DigestAnswer.self, instructions: Self.appleInstructions(language),
                                              prompt: prompt, titled: false)
        for try await snapshot in stream { text = snapshot }
    }

    private func stream(_ client: ClaudeClient, prompt: String, model: ClaudeClient.Model, language: WritingLanguage?) async throws {
        for try await event in client.stream(system: Self.claudeInstructions(language), prompt: prompt, model: model,
                                             effort: "low", maxTokens: 4_096) {
            if case .text(let chunk) = event { text += chunk }
        }
    }

    // MARK: Prompts

    /// Every page numbered, each shortened to an even share of `budget` when they come to more.
    private static func prompt(_ pages: [ReadLaterPage], budget: Int) -> (String, shortened: Bool) {
        let numbered = pages.enumerated().filter { $0.element.text.count > 200 }
        let total = numbered.map { $0.element.text.count }.reduce(0, +)
        // What a short page doesn't use goes to the long ones.
        var share = budget / max(numbered.count, 1)
        let short = numbered.filter { $0.element.text.count < share }
        if !short.isEmpty, short.count < numbered.count {
            share = (budget - short.map { $0.element.text.count }.reduce(0, +)) / (numbered.count - short.count)
        }
        let entries = numbered.map { index, page in (index + 1, page, String(page.text.prefix(share))) }
        return (prompt(entries, budget: budget + 2_000), total > budget)
    }

    private static func prompt(_ entries: [(Int, ReadLaterPage, String)], budget: Int) -> String {
        var prompt = "Saved pages:\n"
        for (number, page, text) in entries {
            let entry = "\n[\(number)] \(page.title) (\(page.site))\n\(text)\n"
            prompt += String(entry.prefix(max(0, budget - prompt.count)))
        }
        return prompt
    }

    private static let condensing = """
        You read a saved web page for someone who will read a summary of several pages at once. \
        Only facts from the page. Write in the page's own language.
        """

    private static func appleInstructions(_ language: WritingLanguage?) -> String {
        """
        You summarize several web pages a person saved to read later, as one summary for a phone. \
        \(language?.instruction ?? "Write in the language of the pages.") Group what they say by theme, \
        not page by page: where pages cover the same subject, put their points together under one \
        theme, and where they disagree, say so. Each point gives the numbers of the pages it comes \
        from. Only facts from the pages, each once. No preamble, no sign-off.
        """
    }

    private static func claudeInstructions(_ language: WritingLanguage?) -> String {
        """
        You summarize several web pages a person saved to read later, as one summary for a phone \
        browser. \(language?.instruction ?? "Write in the language of the pages.") Only facts from \
        the pages, each once, in your own words.

        Format, in Markdown (angle brackets mark what you write):

        @ <article, or general if the pages are mostly not news or essays>
        > <what the pages add up to, one or two sentences>
        ## [<topic>] <theme, two to five words>
        - **<key term>:** <point, one sentence of at most 25 words>[[<page numbers>]]

        Rules: group by theme, not page by page. Three to six "## " themes, each holding what any \
        of the pages say about it; where pages cover the same subject, their points go together, \
        and where they disagree, say so. Two to four "- " points a theme. End every point with the \
        numbers of the pages it comes from in double brackets, as [[2]] or [[1,3]], using the \
        numbers the pages are given; never a number that isn't one of them. The word in brackets \
        after "##" only chooses the theme's icon: pick the closest from [\(AnswerTopic.vocabulary)], \
        or leave the brackets empty, and use each at most once. At most one "!! " line, for the one \
        thing to watch out for, only if a page itself warns of it; never a remark about the pages. No "%% " lines. No emoji. No preamble, no \
        sign-off.
        """
    }

    private static func note(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Marks only for pages that exist: a model's "[[7]]" of five pages goes.
    private static func keepingMarks(_ text: String, upTo count: Int) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\[\[([\d,\s]+)\]\]"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            var seen = Set<Int>()
            let numbers = text[inner].split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { (1...count).contains($0) && seen.insert($0).inserted }
            result.replaceSubrange(whole, with: numbers.isEmpty ? "" : "[[" + numbers.map(String.init).joined(separator: ",") + "]]")
        }
        return result
    }
}

// MARK: Shapes for Apple's models

/// A page read down to what matters, for a digest of many.
@Generable
nonisolated struct PageNotes {
    @Guide(description: "The page's three to five main points, one sentence each, at most 25 words, with its names and numbers", .count(3...5))
    var points: [String]
}

/// One summary across several pages, by theme.
@Generable
nonisolated struct DigestAnswer {
    @Guide(description: "What the pages add up to, in one or two plain sentences")
    var gist: String
    @Guide(description: "Three to five themes the pages cover, each gathering what any of the pages say about it", .count(3...5))
    var themes: [DigestTheme]
    @Guide(description: cautionGuide)
    var caution: String
}

@Generable
nonisolated struct DigestTheme {
    @Guide(description: "What this theme is about, for its icon", .anyOf(AnswerTopic.all))
    var topic: String
    @Guide(description: "A heading of two to five words, written for this theme")
    var heading: String
    @Guide(description: "Two or three points; start each with a key term in **bold** when there is one", .count(2...3))
    var points: [DigestPoint]
}

@Generable
nonisolated struct DigestPoint {
    // First, so the point is written knowing where it comes from: written
    // after it, the small model often left the pages out.
    @Guide(description: "The numbers of the pages this point comes from, as they are numbered in brackets in the prompt", .count(1...3))
    var pages: [Int]
    @Guide(description: "The point, one sentence, at most 25 words")
    var text: String
}

extension DigestAnswer.PartiallyGenerated: AnswerDraft {
    var isUseful: Bool { themes?.isEmpty == false }

    func markdown(titled: Bool, droppingUnfinished: Bool) -> String {
        var themes = self.themes ?? []
        if droppingUnfinished, var last = themes.popLast() {
            last.points = Array((last.points ?? []).dropLast())
            if last.points?.isEmpty == false { themes.append(last) }
        }
        var lines = ["@ article"]
        if let gist, !gist.isEmpty { lines.append("> \(gist)") }
        for theme in themes {
            guard let heading = theme.heading, !heading.isEmpty else { continue }
            lines.append("## [\(theme.topic ?? "")] \(heading)")
            for point in theme.points ?? [] {
                guard let text = point.text, !text.isEmpty else { continue }
                let numbers = (point.pages ?? []).map(String.init).joined(separator: ",")
                lines.append("- \(text)" + (numbers.isEmpty ? "" : "[[\(numbers)]]"))
            }
        }
        if let caution, !caution.isEmpty { lines.append("!! \(caution)") }
        return lines.joined(separator: "\n")
    }
}
