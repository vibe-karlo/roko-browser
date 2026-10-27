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

/// The instructions stay in English whatever the summary is written in:
/// Apple's on-device model refused every request whose instructions were in Croatian.
private func summaryGuidance(_ language: WritingLanguage?) -> String {
    """
    You summarize web pages for a phone browser. \(language?.instruction ?? "Write in the page's own language.") \
    Only facts from the page, and each fact once: never repeat a point. No preamble, no sign-off.
    """
}

/// Says why a summary is in English when it was to be in another language.
private func englishNote(_ language: WritingLanguage) -> String {
    "In English: Apple's models write poor \(language.english)."
}

@Observable
final class SummaryModel: Identifiable {
    enum Phase: Equatable {
        case reading, writing, done, failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let title: String
    let host: String
    var snapshot: UIImage?
    /// Opened by a pull that had already started the card: it carries on from there.
    var handoff: PullHandoff?
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

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The page's address: a summary already written for it is shown at once.
    @ObservationIgnored private var url: URL?

    func start(webView: WKWebView, url: URL?) {
        self.url = url
        if let url, let cached = SummaryCache.entry(for: url) {
            text = cached.text
            engine = cached.engine
            note = cached.note
            phase = .done
            return
        }
        task = Task { await run(webView: webView) }
    }

    /// Stops reading and writing: the summary was closed, and nobody will read the rest.
    func cancel() {
        task?.cancel()
    }

    private func run(webView: WKWebView) async {
        let page: ReadablePage
        do {
            page = try await PageReader.read(webView)
            HitchWatch.note("page read")
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            return
        }
        phase = .writing

        // Apple's models write some languages well and others badly (Croatian
        // with Serbian words and broken endings), and no prompt fixes that. So
        // a summary in a language they write badly goes to Claude first, and
        // when Apple's models write it anyway (no key, Claude off or failing),
        // it's in English. Everything else stays on Apple's models, free and
        // private, with Claude as the fallback.
        // Off the main thread: telling the language took over 100 ms there, in
        // the middle of the card's move into place.
        let (pageText, host, declared) = (page.text, host, page.declaredLanguage)
        let language = await Task.detached(priority: .userInitiated) {
            AnswerLanguage.target(for: pageText, host: host, declared: declared)
        }.value
        let appleWritesIt = language?.appleWritesWell ?? true
        HitchWatch.note("language")
        var engines: [Engine] = [.appleCloud, .onDevice]
        if ClaudeClient.configured != nil { appleWritesIt ? engines.append(.claude) : engines.insert(.claude, at: 0) }

        var lastError: Error = ClaudeError(
            message: "Summaries need Apple Intelligence on this iPhone, or a Claude API key in Settings.")
        for engine in engines {
            do {
                guard try await write(page, with: engine, in: language, appleWritesIt: appleWritesIt) else { continue }
                phase = .done
                SavedStats.summary(pageWords: SavedStats.words(in: page.text), summaryWords: SavedStats.words(in: text))
                if let url, !text.isEmpty {
                    SummaryCache.store(.init(text: text, engine: self.engine, note: note, at: .now), for: url)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                // A cancelled request fails as URLError.cancelled: closed, not failed.
                if Task.isCancelled { return }
                // Quota reached, offline, refused, or out of its depth: try the next engine.
                lastError = error
                text = ""
                note = nil
            }
        }
        phase = .failed(AppleModels.explain(lastError, doing: "summarize this page") ?? lastError.localizedDescription)
    }

    private enum Engine { case appleCloud, onDevice, claude }

    /// Writes the summary with one engine; false when that engine isn't available here.
    private func write(_ page: ReadablePage, with engine: Engine, in language: WritingLanguage?,
                       appleWritesIt: Bool) async throws -> Bool {
        let longNote = "Long page: this covers the first part."
        // Apple's models write English rather than a language they write badly, and say so.
        let appleLanguage = appleWritesIt ? language : .english
        let languageNote = appleWritesIt ? nil : language.map(englishNote)
        switch engine {
        case .appleCloud:
            guard let cloud = AppleModels.cloudIfAvailable else { return false }
            self.engine = "Apple Intelligence"
            let budget = await AppleModels.characterBudget(of: cloud)
            note = Self.note(page.text.count > budget ? longNote : nil, languageNote)
            let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text.prefix(budget))"
            for try await snapshot in AppleModels.streamAnswer(cloud, instructions: summaryGuidance(appleLanguage),
                                                               prompt: prompt, titled: false) {
                text = snapshot
            }

        case .onDevice:
            guard OnDeviceSummarizer.isAvailable else { return false }
            self.engine = "On-device"
            let (stream, truncated) = OnDeviceSummarizer.summarize(page, in: appleLanguage)
            note = Self.note(truncated ? longNote : nil, languageNote)
            let started = CFAbsoluteTimeGetCurrent()
            for try await snapshot in stream {
                if text.isEmpty, !snapshot.isEmpty, LaunchClock.isEnabled {
                    print(String(format: "SUMMARY first words in %.1fs (%d characters on the page)", CFAbsoluteTimeGetCurrent() - started, page.text.count))
                }
                text = snapshot
            }
            if LaunchClock.isEnabled { print(String(format: "SUMMARY finished in %.1fs", CFAbsoluteTimeGetCurrent() - started)) }

        case .claude:
            guard let client = ClaudeClient.configured else { return false }
            self.engine = "Claude"
            let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text)"
            // Haiku: a summary needs no more. Sonnet only if Haiku declines,
            // since Sonnet has a fallback of its own for refusals.
            do {
                try await stream(client, prompt: prompt, model: .haiku, language: language)
            } catch let error as ClaudeError where error.isRefusal {
                text = ""
                try await stream(client, prompt: prompt, model: .sonnet, language: language)
            }
        }
        // Cancelled, a stream just ends: closed, not done.
        try Task.checkCancellation()
        return true
    }

    /// The footer's notes, together; nil when there are none.
    private static func note(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func stream(_ client: ClaudeClient, prompt: String, model: ClaudeClient.Model,
                        language: WritingLanguage?) async throws {
        let instructions = summaryGuidance(language) + "\n\n" + answerShape()
        for try await event in client.stream(system: instructions, prompt: prompt, model: model,
                                             effort: "low", maxTokens: 4_096) {
            if case .text(let chunk) = event { text += chunk }
        }
    }
}

/// Apple's on-device model: free, private and instant, with a small context
/// window. Long pages are condensed chunk by chunk, then summarized as a whole.
enum OnDeviceSummarizer {
    /// What the on-device model reads at a time. The summary starts from the
    /// page's opening, one pass, so its first words come quickly; then, while
    /// it's being read, each later part adds a section or two below. (Reading
    /// every part before writing a word took half a minute on a long feature.)
    private static let partLength = 9_000
    /// Parts read in all: about the first 27,000 characters.
    private static let maxParts = 3

    static var isAvailable: Bool {
        AppleModels.onDeviceAvailable
    }

    /// Streams the growing summary text; `truncated` is true when the page was too long to read in full.
    /// `language`: what to write in; nil follows the page.
    static func summarize(_ page: ReadablePage, in language: WritingLanguage?) -> (AsyncThrowingStream<String, Error>, truncated: Bool) {
        let parts = split(page.text)
        let truncated = parts.count > maxParts
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var summary = ""
                    let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(parts.first ?? "")"
                    for try await markdown in AppleModels.streamAnswer(AppleModels.summarizing,
                                                                       instructions: summaryGuidance(language),
                                                                       prompt: prompt, titled: false) {
                        summary = markdown
                        continuation.yield(summary)
                    }
                    // The rest, a part at a time, added below as it's read.
                    for part in parts.dropFirst().prefix(maxParts - 1) {
                        try Task.checkCancellation()
                        let base = summary
                        let further = "Already in the summary:\n\(base)\n\nA later part of the same page:\n\(part)"
                        for try await more in AppleModels.streamAnswer(AppleModels.summarizing, shape: FurtherSections.self,
                                                                       instructions: summaryGuidance(language) + " Add only what the summary doesn't already say.",
                                                                       prompt: further, titled: false) where !more.isEmpty {
                            summary = base + "\n\n" + more
                            continuation.yield(summary)
                        }
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

    /// The text in parts of about `partLength`, each ending at a paragraph where one is near.
    private static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var cut = rest.prefix(partLength)
            if cut.count == partLength, let end = cut.range(of: "\n\n", options: .backwards),
               cut.distance(from: cut.startIndex, to: end.lowerBound) > partLength / 2 {
                cut = cut[..<end.lowerBound]
            }
            parts.append(String(cut))
            rest = rest.dropFirst(cut.count).drop { $0.isWhitespace }
        }
        return parts
    }
}

/// Summaries already written, by page and language: the same article again
/// opens on its summary at once and costs nothing. Kept for a day (news
/// pages change), a hundred at most, in Caches.
@MainActor
enum SummaryCache {
    struct Entry: Codable {
        let text: String
        let engine: String
        let note: String?
        let at: Date
    }

    private static let lifetime: TimeInterval = 24 * 3600
    private static var file: URL { URL.cachesDirectory.appending(path: "summaries.json") }
    private static var entries: [String: Entry] = {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return saved.filter { Date.now.timeIntervalSince($0.value.at) < lifetime }
    }()

    /// The page without its fragment, and the language summaries are written in.
    static func key(for url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return (parts?.string ?? url.absoluteString) + "|" + AnswerLanguage.signature
    }

    static func entry(for url: URL) -> Entry? {
        guard let entry = entries[key(for: url)], Date.now.timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry
    }

    static func store(_ entry: Entry, for url: URL) {
        entries[key(for: url)] = entry
        if entries.count > 100 {
            for old in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - 100) { entries[old.key] = nil }
        }
        let snapshot = entries
        let file = file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }
}

@Observable
final class BrowseForMeModel: Identifiable {
    enum Phase: Equatable {
        case searching(String), reading(Int), writing, done, failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
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

    /// Asks again after a failure, from the search on.
    func retry() {
        guard phase.isFailure else { return }
        appleError = nil
        text = ""
        sources = []
        steps = []
        images = []
        phase = .searching(query)
        start()
    }

    /// Stops searching and writing: the answer was closed or replaced.
    func cancel() {
        task?.cancel()
        stopLookingForPictures()
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

    private static func claudeInstructions(_ depth: ResearchDepth, language: WritingLanguage?) -> String {
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
        // It also copied sentences from English and Serbian sources straight
        // into Croatian answers, so the language rule covers every sentence.
        let writeIn = language.map { "in \($0.standard ?? $0.english)" } ?? "in the language of the question"
        return """
        You are the "Browse for Me" feature of a phone browser. Always search the web before \
        answering, even when you already know the answer: the person wants current facts with \
        sources they can open. Write every sentence \(writeIn), including facts from sources in \
        other languages: put them in your own words, never copy a source's sentences. \
        Don't list the sources (the app shows them).

        """ + task + """


        After the answer, only if they would genuinely help: two or three short follow-up \
        questions the person is likely to ask next, in the language of the answer, each on \
        its own line starting with "\(followUpMark) ". Nothing after them.
        """
    }

    private static func appleInstructions(_ depth: ResearchDepth, language: WritingLanguage?) -> String {
        let length = switch depth {
        case .quick: "Answer in one to three sentences."
        case .standard: "Lead with what the person most likely wants to know."
        case .deep: "Lead with what the person most likely wants to know, then the specifics the sources give: names, numbers, prices, dates and trade-offs."
        }
        // In a language Apple's models write badly (Croatian, say), they answer
        // in English; Claude answers in the language itself.
        let language = switch language {
        case .some(let language) where !language.appleWritesWell:
            "The answer was to be in \(language.english), which you write poorly: write the whole answer in English."
        case .some(let language): language.instruction
        case nil: "Write in the language of the question."
        }
        return """
        You are the "Browse for Me" feature of a phone browser. The app has searched the web and \
        read the pages below for you. Answer the question using only these sources. Where they \
        disagree, say so. If they don't answer the question, say so once, in the first lines; \
        otherwise write only about what they do say, never about what they leave out. Write the \
        answer itself, not about the sources ("the sources describe..."). \
        \(language) Never repeat a point. \(length)
        """
    }

    func run() async {
        // The language to answer in: chosen in Settings, or the question's own
        // (a follow-up like "i zimi?" is too short to tell, so the page's first
        // question counts too).
        let language = AnswerLanguage.target(for: ([query] + context.map(\.question)).joined(separator: "\n"))
        // Apple's cloud model, fed by our own search, is the default; Claude
        // (which searches by itself) is the fallback; the small on-device model
        // is the last resort, working from search snippets and short excerpts.
        // A language Apple's models write badly goes to Claude first.
        if language?.appleWritesWell == false, let client = ClaudeClient.configured {
            await runClaude(client, language: language)
            return
        }
        if let cloud = AppleModels.cloudIfAvailable,
           await runApple(cloud, budget: await AppleModels.characterBudget(of: cloud, reservingTokens: 1_500),
                          perPage: 6_000, label: "Apple Intelligence", language: language) {
            return
        }
        if let client = ClaudeClient.configured {
            await runClaude(client, language: language)
            return
        }
        if AppleModels.onDeviceAvailable,
           await runApple(SystemLanguageModel.default, budget: AppleModels.onDeviceCharacterBudget(),
                          perPage: 700, label: "On-device", language: language) {
            return
        }
        if case .failed = phase { return }
        // Apple's model was tried and failed: say how, not that it's missing.
        phase = .failed(appleError.flatMap { AppleModels.explain($0, doing: "answer this") }
            ?? "Browse for Me needs Apple Intelligence on this iPhone, or a Claude API key in Settings.")
    }

    /// Why Apple's model last failed here, for the message if nothing else answers.
    @ObservationIgnored private var appleError: Error?

    /// Returns false (leaving the next engine to try) when the model itself fails.
    private func runApple(_ model: some LanguageModel, budget: Int, perPage: Int, label: String,
                          language: WritingLanguage?) async -> Bool {
        do {
            phase = .searching(query)
            // A follow-up leans on the page's question ("how long does the
            // festival last?" after Oktoberfest); searched alone it found Diwali.
            let searchFor = context.first.map { "\($0.question.prefix(100)) \(query)" } ?? query
            let results = try await WebResearcher.search(searchFor)
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
            images = Array(WebResearcher.distinctImages(pages.compactMap(\.image)).prefix(4))
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
            let instructions = Self.appleInstructions(depth, language: language)
            // A quick question gets the short shape: no sections to fill out.
            let answer = depth == .quick
                ? AppleModels.streamAnswer(model, shape: BriefAnswer.self, instructions: instructions, prompt: prompt)
                : AppleModels.streamAnswer(model, shape: ResearchedAnswer.self, instructions: instructions, prompt: prompt)
            for try await snapshot in answer { text = snapshot }
            // Cancelled, the stream just ends: closed, not done.
            try Task.checkCancellation()
            phase = .done
            SavedStats.answer(pagesRead: pages.count, answerWords: SavedStats.words(in: text))
            return true
        } catch is CancellationError {
            return true
        } catch {
            // Closed mid-way (a cancelled request fails as URLError.cancelled):
            // leave it as it was, and don't go on to the next engine.
            if Task.isCancelled { return true }
            appleError = error
            text = ""
            sources = []
            steps = []
            images = []
            phase = .searching(query)
            return false
        }
    }

    private func runClaude(_ client: ClaudeClient, language: WritingLanguage?) async {
        engine = "Claude"
        do {
            do {
                try await streamClaude(client, model: depth.model, language: language)
            } catch let error as ClaudeError where error.isRefusal && depth.model == .haiku && !Task.isCancelled {
                // Haiku declined (it has no fallback of its own): Sonnet answers instead.
                // Only then: a dropped connection isn't helped by the slower,
                // dearer model, and retrying on it spent half a minute for nothing.
                text = ""
                sources = []
                steps = []
                found = []
                images = []
                stopLookingForPictures()
                phase = .searching(query)
                try await streamClaude(client, model: .sonnet, language: language)
            }
            try Task.checkCancellation()
            // An answer that cites nothing still shows where it looked.
            if sources.isEmpty { sources = Array(found.prefix(6)) }
            phase = .done
            SavedStats.answer(pagesRead: max(steps.count, sources.count), answerWords: SavedStats.words(in: text))
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }

    private func streamClaude(_ client: ClaudeClient, model: ClaudeClient.Model, language: WritingLanguage?) async throws {
        for try await event in client.stream(system: Self.claudeInstructions(depth, language: language), prompt: query, history: context,
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
                lookForPicture(on: page.url)
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

    /// Claude reads pages on its own servers, so their pictures aren't at hand:
    /// the first few hits' share images are fetched alongside, while it works.
    /// Each holds a place in the row of pictures until it's found or not. The
    /// first words usually come before the pictures do, and a row appearing
    /// above them then would push the text being read down.
    private func lookForPicture(on url: URL) {
        // Once the answer shows, only into a row that's already there.
        guard pictureLookups.count < 4, isWorking || !images.isEmpty || pendingPictures > 0 else { return }
        pendingPictures += 1
        pictureLookups.append(Task { [weak self] in
            let image = await WebResearcher.shareImage(of: url)
            guard let self, !Task.isCancelled else { return }
            pendingPictures -= 1
            if let image { images = WebResearcher.distinctImages(images + [image]) }
        })
    }

    /// Pictures still being looked for, shown as empty tiles.
    private(set) var pendingPictures = 0
    @ObservationIgnored private var pictureLookups: [Task<Void, Never>] = []

    private func stopLookingForPictures() {
        pictureLookups.forEach { $0.cancel() }
        pictureLookups = []
        pendingPictures = 0
    }
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
            // A long query is a question in all but its punctuation.
            || words.count >= 6
            || text.contains(" or ") || text.contains(" ili ")  // "iPhone or Pixel": a choice
            || deepCues.contains(where: text.contains)
    }

    private static let questionStarts: Set<String> = [
        "what", "who", "whose", "when", "where", "why", "how", "which", "should", "can", "could", "would",
        "will", "is", "are", "was", "were", "do", "does", "did",
        "što", "sto", "šta", "tko", "kada", "kad", "gdje", "zašto", "zasto", "kako", "koji", "koja", "koje",
        "koliko", "kolika", "je", "ima", "isplati", "trebam", "trebaš", "mogu", "može", "smijem", "kakav", "kakva",
        "kakvo", "čiji", "ciji", "objasni", "usporedi", "explain", "compare", "tell",
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
/// The topics a section can be tagged with; each is a Phosphor icon in the assets.
nonisolated enum AnswerTopic {
    static let all = ["idea", "check", "warning", "money", "time", "place", "people", "privacy", "speed", "star",
                      "trend", "learn", "health", "tools", "world", "list", "question", "date", "battery", "device",
                      "code", "nature", "food", "quote", "travel", "sport", "law", "news", "compare", "settings",
                      "weather"]
    static let vocabulary = all.joined(separator: ", ")
}
