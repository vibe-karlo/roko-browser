import FoundationModels
import NaturalLanguage
import UIKit
import WebKit

/// The shape every AI answer takes, so the app can lay it out as a page:
/// a lead line, then a few sections each tagged with a topic the app draws as an icon.
private func answerShape(sections: String = "three to five") -> String {
    """
    Format, in Markdown (angle brackets mark what you write):

    > <the gist, one or two sentences>
    ## [<topic>] <heading for this answer>
    <one or two short sentences>
    ## [<topic>] <heading for this answer>
    - **<key term>:** <detail>
    - **<key term>:** <detail>

    Rules: one "> " line with the gist. Then \(sections) "## " sections with headings written for \
    this answer. The word in brackets only chooses the section's icon: pick the closest from \
    [\(AnswerTopic.vocabulary)], and use each at most once. Under each heading, one or two short \
    sentences or two to four "- " lines. No emoji. No preamble, no sign-off.
    """
}

/// Claude writes Croatian well when told which standard to keep to.
private let croatianStandard = """
In Croatian, write standard Croatian (ijekavica): Croatian words, never Serbian or Bosnian ones.
"""

private let summaryGuidance = """
You summarize web pages for a phone browser. Write in the page's own language. \
Only facts from the page, and each fact once: never repeat a point. No preamble, no sign-off.
"""

/// For Claude. (Apple's on-device model refused every request whose
/// instructions were written in Croatian, so it keeps the plain guidance above.)
private let summaryInstructions = summaryGuidance + " " + croatianStandard + "\n\n" + answerShape()

@Observable
final class SummaryModel: Identifiable {
    enum Phase: Equatable {
        case reading, writing, done, failed(String)
    }

    let title: String
    let host: String
    var snapshot: UIImage?
    /// The page's size when the summary opened (below 1 after a pinch).
    var startScale: CGFloat = 1
    /// Growing back into the page: the status bar takes the site's colour again.
    var isClosing = false
    private(set) var text = ""
    private(set) var phase: Phase = .reading
    private(set) var engine = ""
    private(set) var note: String?

    init(title: String, host: String, snapshot: UIImage?) {
        self.title = title
        self.host = host
        self.snapshot = snapshot
    }

    /// Reading the page or waiting for the first words: the light is up.
    var isWorking: Bool {
        phase == .reading || phase == .writing && text.isEmpty
    }

    /// For the light: lower while the page is read, higher while the first words come.
    var progress: Double {
        phase == .reading ? 0.35 : 0.8
    }

    func run(webView: WKWebView) async {
        let page: ReadablePage
        do {
            page = try await PageReader.read(webView)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .writing

        // Apple's models write good English and poor Croatian (Serbian words,
        // broken endings), and no prompt fixes that. So a Croatian page goes
        // to Claude first; everything else stays on Apple's models, free and
        // private, with Claude as the fallback.
        let claudeFirst = AnswerLanguage.of(page.text, host: host) == .croatian
        var engines: [Engine] = [.appleCloud, .onDevice]
        if ClaudeClient.configured != nil { claudeFirst ? engines.insert(.claude, at: 0) : engines.append(.claude) }

        var lastError: Error = ClaudeError(
            message: "Summaries need Apple Intelligence on this iPhone, or a Claude API key in Settings.")
        for engine in engines {
            do {
                guard try await write(page, with: engine) else { continue }
                phase = .done
                return
            } catch is CancellationError {
                return
            } catch {
                // Quota reached, offline, refused, or out of its depth: try the next engine.
                lastError = error
                text = ""
                note = nil
            }
        }
        phase = .failed(lastError.localizedDescription)
    }

    private enum Engine { case appleCloud, onDevice, claude }

    /// Writes the summary with one engine; false when that engine isn't available here.
    private func write(_ page: ReadablePage, with engine: Engine) async throws -> Bool {
        switch engine {
        case .appleCloud:
            guard let cloud = AppleModels.cloudIfAvailable else { return false }
            self.engine = "Apple Intelligence"
            let budget = await AppleModels.characterBudget(of: cloud)
            if page.text.count > budget { note = "Long page: this covers the first part." }
            let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text.prefix(budget))"
            for try await snapshot in AppleModels.streamAnswer(cloud, instructions: summaryGuidance, prompt: prompt, titled: false) {
                text = snapshot
            }

        case .onDevice:
            guard OnDeviceSummarizer.isAvailable else { return false }
            self.engine = "On-device"
            let (stream, truncated) = OnDeviceSummarizer.summarize(page)
            if truncated { note = "Long page: this covers the first part." }
            for try await snapshot in stream { text = snapshot }

        case .claude:
            guard let client = ClaudeClient.configured else { return false }
            self.engine = "Claude"
            let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text)"
            // Haiku: a summary needs no more. Sonnet only if Haiku declines,
            // since Sonnet has a fallback of its own for refusals.
            do {
                try await stream(client, prompt: prompt, model: .haiku)
            } catch let error as ClaudeError where error.isRefusal {
                text = ""
                try await stream(client, prompt: prompt, model: .sonnet)
            }
        }
        return true
    }

    private func stream(_ client: ClaudeClient, prompt: String, model: ClaudeClient.Model) async throws {
        for try await event in client.stream(system: summaryInstructions, prompt: prompt, model: model,
                                             effort: "low", maxTokens: 4_096) {
            if case .text(let chunk) = event { text += chunk }
        }
    }
}

/// Apple's on-device model: free, private and instant, with a small context
/// window. Long pages are condensed chunk by chunk, then summarized as a whole.
enum OnDeviceSummarizer {
    private static let chunkLength = 7_000
    private static let maxChunks = 6

    static var isAvailable: Bool {
        AppleModels.onDeviceAvailable
    }

    /// Streams the growing summary text; `truncated` is true when the page was too long to read in full.
    static func summarize(_ page: ReadablePage) -> (AsyncThrowingStream<String, Error>, truncated: Bool) {
        let chunks = chunked(page.text)
        let truncated = chunks.count > maxChunks
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var material = chunks.first ?? ""
                    if chunks.count > 1 {
                        var notes: [String] = []
                        for chunk in chunks.prefix(maxChunks) {
                            let session = LanguageModelSession(
                                model: AppleModels.summarizing,
                                instructions: "List the key facts in this part of a web page as three to five short lines starting with \"- \". Nothing else.")
                            notes.append(try await session.respond(to: chunk).content)
                        }
                        material = notes.joined(separator: "\n")
                    }

                    let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(material)"
                    for try await markdown in AppleModels.streamAnswer(AppleModels.summarizing, instructions: summaryGuidance,
                                                                       prompt: prompt, titled: false) {
                        continuation.yield(markdown)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, truncated)
    }

    private static func chunked(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > chunkLength, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + String(paragraph.prefix(chunkLength))
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

@Observable
final class BrowseForMeModel: Identifiable {
    enum Phase: Equatable {
        case searching(String), reading(Int), writing, done, failed(String)
    }

    /// One page being read, for the live list while you wait.
    struct Step: Identifiable, Equatable {
        enum State { case reading, read, skipped }
        let url: URL
        var state: State
        var id: URL { url }
    }

    let query: String
    /// Quick fact, ordinary question, or one worth real research.
    let depth: ResearchDepth
    private(set) var text = ""
    private(set) var sources: [Source] = []
    private(set) var steps: [Step] = []
    /// Pictures from the sources, shown above the answer.
    private(set) var images: [URL] = []
    private(set) var phase: Phase = .searching("")
    private(set) var engine = ""
    /// Earlier questions and answers on the same page, for a follow-up.
    let context: [(question: String, answer: String)]

    init(query: String, context: [(question: String, answer: String)] = []) {
        self.query = query
        self.context = context
        depth = ResearchDepth.of(query)
    }

    /// Still finding: no answer text yet.
    var isWorking: Bool {
        switch phase {
        case .searching, .reading: true
        case .writing: text.isEmpty
        case .done, .failed: false
        }
    }

    /// How far along the finding is, 0 to 1, for the light that rises while you wait.
    var progress: Double {
        switch phase {
        case .searching:
            // Claude's own searches turn up pages before any reading phase.
            0.12 + 0.5 * min(1, Double(steps.count) / 8)
        case .reading(let count):
            0.3 + 0.5 * Double(steps.filter { $0.state != .reading }.count) / Double(max(count, 1))
        case .writing: text.isEmpty ? 0.9 : 1
        case .done, .failed: 1
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        task = Task { await run() }
    }

    /// Stops searching and writing: the answer was closed or replaced.
    func cancel() {
        task?.cancel()
    }

    /// The answer without its follow-up lines (nor the lone "?" a follow-up
    /// line starts as while it streams in).
    var answer: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                return line != "?" && !line.hasPrefix(Self.followUpMark)
            }
            .joined(separator: "\n")
    }

    /// Questions to ask next, once the answer is complete. Written by the model
    /// as lines starting with "?? ", only when they'd genuinely help.
    var followUps: [String] {
        guard phase == .done else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(Self.followUpMark) }
            .map { String($0.dropFirst(Self.followUpMark.count)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { $0 }
    }

    static let followUpMark = "??"

    private static func claudeInstructions(_ depth: ResearchDepth) -> String {
        let task = switch depth {
        case .quick: """
            Answer briefly. One or two searches and two or three good sources are enough. First \
            line: "# " and a specific title. Then one "> " line with the direct answer in one to \
            three sentences. Then at most three "- " lines of supporting detail, only if they \
            help. No "## " sections. No emoji. No preamble, no sign-off.
            """
        case .standard: """
            One to three searches and four to six trustworthy sources. Write a compact answer \
            page. First line: "# " and a specific title. Lead with what the person most likely \
            wants to know.
            """ + answerShape()
        case .deep: """
            Research this properly: search from several angles and read at least six \
            trustworthy sources. Give specifics: names, numbers, prices, dates and trade-offs. \
            Where sources disagree, say so. First line: "# " and a specific title. Lead with \
            what the person most likely wants to know.
            """ + answerShape(sections: "five to seven")
        }
        // Haiku answered "why is the sky blue" from memory, with no search and
        // so no sources; the feature promises an answer read from the web.
        return """
        You are the "Browse for Me" feature of a phone browser. Always search the web before \
        answering, even when you already know the answer: the person wants current facts with \
        sources they can open. Answer in the language of the question. \(croatianStandard) \
        Don't list the sources (the app shows them).

        """ + task + """


        After the answer, only if they would genuinely help: two or three short follow-up \
        questions the person is likely to ask next, in the language of the question, each on \
        its own line starting with "\(followUpMark) ". Nothing after them.
        """
    }

    private static func appleInstructions(_ depth: ResearchDepth, question: String) -> String {
        let length = switch depth {
        case .quick: "Answer in one to three sentences."
        case .standard: "Lead with what the person most likely wants to know."
        case .deep: "Lead with what the person most likely wants to know, then give specifics: names, numbers, prices, dates and trade-offs."
        }
        // Told only "the language of the question", the small model answers a
        // Croatian question in English (its sources are often English), so name it.
        let language = AnswerLanguage.of(question) == .croatian
            ? "Write the whole answer in Croatian." : "Write in the language of the question."
        return """
        You are the "Browse for Me" feature of a phone browser. The app has searched the web and \
        read the pages below for you. Answer the question using only these sources. Where they \
        disagree, say so; if they don't answer part of the question, say what is missing. \
        \(language) Never repeat a point. \(length)
        """
    }

    func run() async {
        // Apple's cloud model, fed by our own search, is the default; Claude
        // (which searches by itself) is the fallback; the small on-device model
        // is the last resort, working from search snippets and short excerpts.
        if let cloud = AppleModels.cloudIfAvailable,
           await runApple(cloud, budget: await AppleModels.characterBudget(of: cloud, reservingTokens: 1_500),
                          perPage: 6_000, label: "Apple Intelligence") {
            return
        }
        if let client = ClaudeClient.configured {
            await runClaude(client)
            return
        }
        if AppleModels.onDeviceAvailable,
           await runApple(SystemLanguageModel.default, budget: AppleModels.onDeviceCharacterBudget(),
                          perPage: 700, label: "On-device") {
            return
        }
        if case .failed = phase { return }
        phase = .failed("Browse for Me needs Apple Intelligence on this iPhone, or a Claude API key in Settings.")
    }

    /// Returns false (leaving the next engine to try) when the model itself fails.
    private func runApple(_ model: some LanguageModel, budget: Int, perPage: Int, label: String) async -> Bool {
        do {
            phase = .searching(query)
            let results = try await WebResearcher.search(query)
            guard !results.isEmpty else {
                phase = .failed("The search came back empty. Try wording it differently.")
                return true
            }
            let candidates = Array(results.prefix(depth.pages))
            steps = candidates.map { Step(url: $0.url, state: .reading) }
            phase = .reading(candidates.count)
            var pages = await WebResearcher.read(candidates, perPageLimit: perPage) { [weak self] url, useful in
                guard let self, let index = self.steps.firstIndex(where: { $0.url == url }) else { return }
                self.steps[index].state = useful ? .read : .skipped
            }
            images = Array(pages.compactMap(\.image).prefix(4))
            // Pages that wouldn't load still contribute their search snippet.
            if pages.count < 2 { pages = candidates.map { var page = $0; page.text = $0.snippet; return page } }
            sources = pages.map { Source(url: $0.url, title: $0.title) }

            // A follow-up carries the page so far, briefly, so "and in winter?" makes sense.
            var prompt = context.isEmpty ? "" : "Earlier on this page:\n" + context.map {
                "Q: \($0.question)\nA: \($0.answer.prefix(600))"
            }.joined(separator: "\n\n") + "\n\n"
            prompt += "Question: \(query)\n\nSources:\n"
            for (index, page) in pages.enumerated() {
                let entry = "\n[\(index + 1)] \(page.title) (\(page.url.displayHost))\n\(page.text)\n"
                if prompt.count + entry.count > budget {
                    prompt += String(entry.prefix(max(0, budget - prompt.count)))
                    break
                }
                prompt += entry
            }

            engine = label
            phase = .writing
            let instructions = Self.appleInstructions(depth, question: query)
            // A quick question gets the short shape: no sections to fill out.
            let answer = depth == .quick
                ? AppleModels.streamAnswer(model, shape: BriefAnswer.self, instructions: instructions, prompt: prompt)
                : AppleModels.streamAnswer(model, shape: ResearchedAnswer.self, instructions: instructions, prompt: prompt)
            for try await snapshot in answer { text = snapshot }
            phase = .done
            return true
        } catch is CancellationError {
            return true
        } catch {
            text = ""
            sources = []
            steps = []
            images = []
            phase = .searching(query)
            return false
        }
    }

    private func runClaude(_ client: ClaudeClient) async {
        engine = "Claude"
        do {
            do {
                try await streamClaude(client, model: depth.model)
            } catch let error where depth.model == .haiku && !(error is CancellationError) {
                // Haiku declined (it has no fallback of its own): Sonnet answers instead.
                text = ""
                sources = []
                steps = []
                found = []
                phase = .searching(query)
                try await streamClaude(client, model: .sonnet)
            }
            // An answer that cites nothing still shows where it looked.
            if sources.isEmpty { sources = Array(found.prefix(6)) }
            phase = .done
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func streamClaude(_ client: ClaudeClient, model: ClaudeClient.Model) async throws {
        for try await event in client.stream(system: Self.claudeInstructions(depth), prompt: query, history: context,
                                             model: model, effort: depth.effort, searches: depth.searches) {
            switch event {
            case .searching(let query):
                phase = .searching(query)
            case .usingTool:
                // Whatever it wrote so far was it thinking aloud between searches.
                if !text.isEmpty {
                    text = ""
                    phase = .searching(query)
                }
            case .result(let page):
                // Search hits: a few on the live list while it works, the rest
                // kept in case the answer cites nothing.
                guard !found.contains(where: { $0.url.displayHost == page.url.displayHost }) else { break }
                found.append(page)
                if steps.count < 8 { steps.append(Step(url: page.url, state: .read)) }
            case .source(let page):
                // Cited by the answer: these are its sources.
                if !sources.contains(where: { $0.url.displayHost == page.url.displayHost }) { sources.append(page) }
            case .text(let chunk):
                text += chunk
                phase = .writing
            }
        }
    }

    /// Pages Claude's searches turned up, whether or not the answer used them.
    private var found: [Source] = []
}

/// How much digging a question deserves, judged from its words alone: on the
/// phone, instantly, with no model call. A quick fact wants its answer now; a
/// comparison, a "best", a plan or a long question wants more sources and room.
nonisolated enum ResearchDepth: Equatable {
    case quick, standard, deep

    static func of(_ question: String) -> ResearchDepth {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // Padded with spaces so a cue matches whole words (or, for Croatian, word stems).
        let text = " " + words.joined(separator: " ") + " "
        guard let first = words.first else { return .standard }
        let asksForAFact = quickStarts.contains(first)
            || first == "how" && words.count > 1 && howMuch.contains(words[1])
        // "or" makes a comparison ("iPhone or Pixel"), but not in a fact
        // question ("is it open or closed today").
        let compares = !asksForAFact && (text.contains(" or ") || text.contains(" ili "))
        if words.count >= 12 || compares || deepCues.contains(where: text.contains) { return .deep }
        // A recipe, a how-to or an explanation needs room, however short the question.
        if roomCues.contains(where: text.contains) { return .standard }
        if words.count <= 3 || words.count <= 7 && asksForAFact { return .quick }
        return .standard
    }

    /// Choosing or planning: comparisons, the best of something, whether it's
    /// worth it, a trip. Explanations ("why", "how does") are standard: one
    /// good source explains as well as eight.
    fileprivate static let deepCues = [
        " vs ", " versus ", " compare", " comparison", " difference", " pros and cons", " best ", " top ",
        " review", " should i ", " worth ", " alternative", " plan ", " itinerary", " guide", " recommend",
        " usporedb", " razlik", " najbolj", " isplati", " prednost", " nedostat", " mane ", " recenzij",
        " preporu", " vodič", " savjet", " ideje ",
    ]
    private static let roomCues = [" recipe", " recept", " how to ", " kako ", " tutorial", " upute", " steps ",
                                   " explain", " objasni", " why ", " zašto ", " zasto "]
    private static let quickStarts: Set<String> = [
        "what", "who", "when", "where", "which", "whose", "is", "are", "was", "were", "does", "did", "can",
        "koliko", "kolika", "kada", "kad", "tko", "gdje", "koji", "koja", "koje", "što", "sto", "je", "ima",
    ]
    private static let howMuch: Set<String> = ["many", "much", "old", "tall", "long", "far", "big", "fast"]

    /// Pages read for Apple's models, which get no searches of their own.
    var pages: Int {
        switch self { case .quick: 3; case .standard: 6; case .deep: 8 }
    }

    /// Claude's web searches. Each one adds its results to what every later
    /// step re-reads, so more searches cost time and tokens twice over.
    var searches: Int {
        switch self { case .quick: 2; case .standard: 3; case .deep: 6 }
    }

    /// Haiku streams its answer from the first word; Sonnet's arrives in one
    /// burst once mostly written. So Haiku for everything but the questions
    /// that need weighing many sources.
    var model: ClaudeClient.Model { self == .deep ? .sonnet : .haiku }

    /// Whether a typed query asks for an answer rather than for a page: a
    /// question ("can dogs eat grapes", "zašto…"), a comparison or a decision.
    /// Keywords, site names, weather, maps and logins stay searches: the
    /// search engine's own results answer those better.
    static func prefersAnswer(_ query: String) -> Bool {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.count >= 3, let first = words.first else { return false }
        let text = " " + words.joined(separator: " ") + " "
        if searchCues.contains(where: text.contains) { return false }
        return query.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            || questionStarts.contains(first)
            || text.contains(" or ") || text.contains(" ili ")  // "iPhone or Pixel": a choice
            || deepCues.contains(where: text.contains)
    }

    private static let questionStarts: Set<String> = [
        "what", "who", "whose", "when", "where", "why", "how", "which", "should", "can", "could", "would",
        "will", "is", "are", "was", "were", "do", "does", "did",
        "što", "sto", "šta", "tko", "kada", "kad", "gdje", "zašto", "zasto", "kako", "koji", "koja", "koje",
        "koliko", "kolika", "je", "ima", "isplati", "trebam", "trebaš", "mogu", "može", "smijem",
    ]
    private static let searchCues = [
        " weather", " vrijeme u ", " prognoza", " near me", " u blizini", " login", " log in", " sign in",
        " prijava", " download", " preuzmi", " youtube", " reddit", " wikipedia", " map ", " maps ",
        " karta ", " lyrics", " tekst pjesme", " live ", " uživo", " stock price",
    ]

    /// Deep questions get more sources and room, not more thinking: high
    /// effort spent 16 s thinking before the first word, measured on a phone.
    var effort: String {
        switch self { case .quick: "low"; case .standard, .deep: "medium" }
    }
}

/// The language an answer will be written in, as far as choosing a model goes:
/// Apple's on-device model writes Croatian with Serbian words and broken
/// endings, so Croatian goes to Claude when there's a key.
nonisolated enum AnswerLanguage {
    case croatian, other

    /// From the page's (or question's) own text. Croatian, Serbian and Bosnian
    /// in Latin script are close enough to be confused for one another, so
    /// those count as Croatian on a .hr site or on a phone set to Croatia.
    static func of(_ text: String, host: String = "") -> AnswerLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let language = recognizer.dominantLanguage else { return .other }
        if language == .croatian { return .croatian }
        let neighbours: Set<NLLanguage> = [NLLanguage("sr"), NLLanguage("bs")]
        let isCyrillic = text.prefix(400).unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        if neighbours.contains(language), !isCyrillic,
           host.hasSuffix(".hr") || Locale.current.region?.identifier == "HR" {
            return .croatian
        }
        return .other
    }
}

/// The topics a section can be tagged with; each is a Phosphor icon in the assets.
nonisolated enum AnswerTopic {
    static let all = ["idea", "check", "warning", "money", "time", "place", "people", "privacy", "speed", "star",
                      "trend", "learn", "health", "tools", "world", "list", "question", "date", "battery", "device",
                      "code", "nature", "food", "quote", "travel", "sport", "law", "news", "compare", "settings"]
    static let vocabulary = all.joined(separator: ", ")
}
