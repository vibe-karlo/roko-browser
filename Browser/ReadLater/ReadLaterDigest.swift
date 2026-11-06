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
    private(set) var pages: [ReadLaterPage]
    /// Several sites' stories about one event, to compare rather than summarize.
    private let comparing: [NewsStory]?
    var isComparison: Bool { comparing != nil }
    /// The group's name, for a group's summary; nil for all of them.
    let subject: String?
    private(set) var text = ""
    private(set) var phase: Phase = .reading
    private(set) var engine = ""
    private(set) var note: String?

    init(pages: [ReadLaterPage], subject: String? = nil) {
        self.pages = pages
        self.subject = subject
        comparing = nil
    }

    /// One event as several sites report it: at most one story from a site
    /// unless there's room, six in all. Their text is read when it starts.
    init(comparing stories: [NewsStory]) {
        var seen = Set<String>()
        let firsts = stories.filter { seen.insert($0.host).inserted }
        let chosen = Array((firsts + stories.filter { story in !firsts.contains { $0.link == story.link } }).prefix(6))
        comparing = chosen
        subject = StoryGroups.title(of: stories)
        pages = chosen.map { story in
            var page = ReadLaterPage(url: story.link, title: story.title, site: story.host, text: "")
            page.id = FeedStore.pageID(for: story.link)
            return page
        }
    }

    func story(of page: ReadLaterPage) -> NewsStory? {
        comparing?.first { $0.link == page.url }
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
        if let kept = isComparison ? FeedStore.shared.comparison(of: pages) : ReadLater.shared.digest(for: pages) {
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
        if let comparing { await gather(comparing) }
        if Task.isCancelled { return }
        let readable = pages.filter { $0.text.count > 200 }
        guard !readable.isEmpty else {
            phase = .failed(isComparison ? "Couldn't read any of these articles here."
                                         : "None of these pages had text to read when they were saved.")
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
                if isComparison {
                    text = Self.provable(text, from: pages)
                    // Nothing provable isn't "no differences": it's no comparison.
                    guard text.contains("[[") else {
                        throw ClaudeError(message: ClaudeClient.configured == nil
                                          ? "Apple's model couldn't compare these articles. With a Claude API key in Settings, Claude does."
                                          : "Couldn't compare these articles here. Open one to read it.")
                    }
                }
                phase = .done
                SavedStats.summary(pageWords: pages.map(\.words).reduce(0, +), summaryWords: SavedStats.words(in: text))
                let kept = ReadLater.Digest(pageIDs: pages.map(\.id), text: text, engine: self.engine, note: note, at: .now)
                if isComparison { FeedStore.shared.keep(kept) } else { ReadLater.shared.keep(kept) }
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
        phase = .failed(AppleModels.explain(lastError, doing: isComparison ? "compare these articles" : "summarize these pages") ?? lastError.localizedDescription)
    }

    // MARK: Comparing

    /// Which sites ran one text, said under the comparison; kept across a retry's reading.
    private var sameText: String?
    private var headings = ComparisonHeadings.english

    /// Reads each story's text, and leaves out a copy of one already read: it
    /// would only count as agreement. Three at a time, as each may load a page.
    private func gather(_ stories: [NewsStory]) async {
        condensed = 0
        sameText = nil
        var texts: [URL: String] = [:]
        for start in stride(from: 0, to: stories.count, by: 3) {
            let reading = stories[start..<min(start + 3, stories.count)].map { story in
                (story.link, Task { await FeedStore.shared.text(of: story) })
            }
            for (link, task) in reading {
                texts[link] = await task.value
                condensed += 1
            }
        }
        condensed = 0
        for index in pages.indices { pages[index].text = texts[pages[index].url] ?? "" }
        var copies: [(of: String, copy: String)] = []
        for index in pages.indices where pages[index].text.count > 200 {
            if let original = pages[..<index].first(where: { $0.text.count > 200 && Self.sameWords($0.text, pages[index].text) }) {
                copies.append((original.site, pages[index].site))
                pages[index].text = ""
            }
        }
        if !copies.isEmpty {
            let names = (copies.map(\.of) + copies.map(\.copy)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            sameText = "The same text on \(names.formatted(.list(type: .and)))."
        }
    }

    /// Nearly every run of five words in one is in the other too.
    private static func sameWords(_ a: String, _ b: String) -> Bool {
        func runs(_ text: String) -> Set<String> {
            let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
            guard words.count >= 5 else { return [] }
            return Set((0...(words.count - 5)).map { words[$0..<($0 + 5)].joined(separator: " ") })
        }
        let left = runs(String(a.prefix(6_000))), right = runs(String(b.prefix(6_000)))
        guard !left.isEmpty, !right.isEmpty else { return false }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count)) >= 0.8
    }

    /// Only what can be shown from the articles: a point has to name its
    /// sources, and every number in it has to be in them. A made-up difference
    /// would be worse than none. Then a heading left with nothing goes: no
    /// differences, no section saying so.
    private static func provable(_ text: String, from pages: [ReadLaterPage]) -> String {
        func numbers(in text: String) -> Set<String> {
            Set(text.matches(of: /\d[\d.,]*\d/).map { String($0.0).filter(\.isNumber) })
        }
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard line.hasPrefix("- ") else {
                kept.append(line)
                continue
            }
            guard let mark = line.firstMatch(of: /\[\[([\d,\s]+)\]\]/) else { continue }
            let cited = mark.1.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .compactMap { pages.indices.contains($0 - 1) ? pages[$0 - 1].text : nil }
            let found = numbers(in: cited.joined(separator: " "))
            if numbers(in: String(line[..<mark.range.lowerBound])).isSubset(of: found) { kept.append(line) }
        }
        var result: [String] = []
        for (index, line) in kept.enumerated() {
            if line.hasPrefix("## "), !(kept.indices.contains(index + 1) && kept[index + 1].hasPrefix("- ")) { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    /// "Article 2" means nothing on screen: the site's name does. "Articles 1 and 2"
    /// keep their "and". Not when the articles say it themselves: "Article 2 of the
    /// constitution" is about the constitution. As it's written too, so the words
    /// don't change once it's done.
    private static func namingSites(_ text: String, from pages: [ReadLaterPage]) -> String {
        func site(_ number: Substring) -> String? {
            Int(number).flatMap { pages.indices.contains($0 - 1) ? pages[$0 - 1].site : nil }
        }
        let numbered = text.replacing(/\b(?:articles?|članak|članka|članku|članci|članaka|člancima|sources?|izvora?|izvoru|izvori)\s+(\d(?:\s*(?:,|and|&|i)\s*\d)*)\b/.ignoresCase()) { match -> String in
            let said = String(match.0)
            let digits = match.1.matches(of: /\d/).map(\.0)
            guard digits.allSatisfy({ site($0) != nil }),
                  !pages.contains(where: { $0.text.localizedCaseInsensitiveContains(said) }) else { return said }
            return String(match.1).replacing(/\d/) { site($0.0) ?? String($0.0) }
        }
        // A number on its own in the sentence, which the marks' double brackets aren't.
        return numbered.replacing(/(^|[^\[])\[(\d(?:\s*,\s*\d)*)\](?!\])/) { match -> String in
            let digits = match.2.matches(of: /\d/).map(\.0)
            guard digits.allSatisfy({ site($0) != nil }) else { return String(match.0) }
            return match.1 + "(" + digits.compactMap(site).joined(separator: ", ") + ")"
        }
    }

    /// One engine's go; false when it isn't available here.
    private func write(with engine: Engine, language: WritingLanguage?, appleWritesIt: Bool) async throws -> Bool {
        let appleLanguage = appleWritesIt ? language : .english
        let languageNote = appleWritesIt ? nil : language.map { "In English: Apple's models write poor \($0.english)." }
        headings = ComparisonHeadings.for(engine == .claude ? language : appleLanguage)
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
            note = Self.note(sameText, shortened ? "Long pages: their first parts." : nil)
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
        note = Self.note(sameText, shortened ? "Long pages: their first parts." : nil, languageNote)
        phase = .writing
        if isComparison {
            // Plain text, not a shape to fill: Apple's permissive guardrails only
            // apply to plain text, and news filled into a shape was turned down
            // ("May contain sensitive content") even for an interest rate rise.
            let session = LanguageModelSession(model: model, instructions: Self.appleComparing(language))
            var written = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                written = snapshot.content
                text = Self.namingSites(headings.markdown(fromLines: written, sites: pages.map(\.site)), from: pages)
            }
            AITrace.log("compare wrote: \(written)")
            return
        }
        let stream = AppleModels.streamAnswer(model, shape: DigestAnswer.self, instructions: Self.appleInstructions(language),
                                              prompt: prompt, titled: false)
        for try await snapshot in stream { text = snapshot }
    }

    private func stream(_ client: ClaudeClient, prompt: String, model: ClaudeClient.Model, language: WritingLanguage?) async throws {
        let system = isComparison ? Self.claudeComparing(language, headings: headings) : Self.claudeInstructions(language)
        var written = ""
        for try await event in client.stream(system: system, prompt: prompt, model: model,
                                             effort: "low", maxTokens: 4_096) {
            guard case .text(let chunk) = event else { continue }
            written += chunk
            text = isComparison ? Self.namingSites(written, from: pages) : written
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

    private static func appleComparing(_ language: WritingLanguage?) -> String {
        """
        You tell someone what several news articles about one event say, for a phone. \(language?.instruction ?? "Write in the language of the articles.") \
        Write one account of the event from all the articles together, never one per article. Write about the event and its details, not about the articles or how they compare. Only what the articles say, each thing \
        once. Never guess why a site wrote something. Answer in lines of exactly this form, the numbers in brackets being the \
        articles it comes from:

        GIST: what happened, in one or two plain sentences
        POINT [1,2]: a fact or detail from the articles, with its names and numbers
        DIFF [1,2]: one site's name says one thing, another site's name says something else that can't also be true

        One GIST. Three to six POINT lines, the most important first, each a new fact, never repeating the GIST or another line, \
        including what only one article has. DIFF lines come last, only where two articles really contradict each other: most \
        stories have none, and never make one up. A detail only one article gives is a POINT, not a DIFF, and so is the same thing in \
        other words. Each line at most 30 words. Call a site by the name in brackets after its title, never "article 2" or "the \
        first article". Nothing else.
        """
    }

    private static func claudeComparing(_ language: WritingLanguage?, headings: ComparisonHeadings) -> String {
        """
        You tell someone what several news articles about one event say, for a phone browser. \(language?.instruction ?? "Write in the language of the articles.") \
        Write about the event and its details, not about the articles or how they compare. Only what the articles say, each thing \
        once, in your own words.

        Format, in Markdown (angle brackets mark what you write; keep the last heading exactly as it is):

        @ article
        > <what happened, one or two sentences>
        ## [<topic>] <theme, two to five words>
        - **<key term>:** <a fact or detail with its names and numbers, one sentence of at most 25 words>[[<article numbers>]]
        ## [compare] \(headings.differ)
        - **<key term>:** <what each one says, at most 35 words>[[<article numbers>]]

        Rules: one to three themes of the story itself, most important first, two to four points each, including what only one \
        article has. The word in brackets after "##" only chooses the theme's icon: pick the closest from [\(AnswerTopic.vocabulary)], \
        or leave the brackets empty. The last heading is only for real conflicts: contradictions, or different numbers, names or \
        causes. Most stories have none, so leave it out; a different emphasis isn't a conflict, never make one up, and never guess why \
        a site wrote something. End every point with the numbers of the articles it comes from in double brackets, as [[2]] or \
        [[1,3]], using the numbers the articles are given. Say which site only when a detail needs it, by the name in brackets after \
        its title, never "article 2" or "the first article". No "!! " or "%% " lines. No emoji. No preamble, no sign-off.
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

// MARK: A comparison's headings

/// Fixed, so what they mean doesn't depend on the model. Croatian, as roko's
/// news is, and English for the rest.
nonisolated struct ComparisonHeadings {
    let story, differ: String

    static let english = ComparisonHeadings(story: "What they report", differ: "Where they differ")
    static let croatian = ComparisonHeadings(story: "Što pišu", differ: "Gdje se razlikuju")

    static func `for`(_ language: WritingLanguage?) -> ComparisonHeadings {
        language?.code.hasPrefix("hr") == true ? croatian : english
    }

    /// What Apple's models write ("POINT [1,2]: …"), in the app's Markdown. A
    /// line that isn't of the form, as one being written isn't yet, is left out.
    /// A point without numbers comes from all of them, and has to prove it. A conflict
    /// has to name both sides: this model finds "kuhinjski" against "kuhinjskim" a
    /// difference, and one that can't say who says what is none worth a note.
    func markdown(fromLines draft: String, sites: [String]) -> String {
        var gist: String?
        var sections: [String: [String]] = [:]
        let allOfThem = sites.indices.map { String($0 + 1) }.joined(separator: ",")
        var said: [Set<String>] = []
        for line in draft.split(separator: "\n") {
            // The numbers come before the word about as often as after it: "[1,2] POINT:", and
            // "[1][2] POINT 3:". Often there's no word at all, only numbers: that's a point.
            let kind: String, before: Substring, after: Substring, written: Substring
            if let match = line.firstMatch(of: /^\W*((?:\[[\d,\s]*\]\W*)*)(GIST|POINT|DIFF)[^\w\[]*(?:\d+[^\w\[]*)?((?:\[[\d,\s]*\][^\w\[]*)*)(.+)$/) {
                (kind, before, after, written) = (String(match.2), match.1, match.3, match.4)
            } else if let match = line.firstMatch(of: /^\W*((?:\[[\d,\s]*\]\W*)+)(.+)$/) {
                (kind, before, after, written) = ("POINT", match.1, "", match.2)
            } else {
                continue
            }
            // Its sources again, in words: "(index.hr) Osam policajaca … (1,2)".
            let body = written.replacing(/^\([^)]*\)\s*/, with: "").replacing(/\s*\([\d,\s]+\)\.?\s*$/, with: "").trimmingCharacters(in: .whitespaces)
            // Only its numbers so far, as it's being written.
            guard body.contains(where: \.isLetter) else { continue }
            let opening = body.prefix(1).uppercased() + body.dropFirst()
            if kind == "GIST" {
                gist = gist ?? opening
                continue
            }
            if kind == "DIFF", Set(sites.filter { !$0.isEmpty && body.lowercased().contains($0.lowercased()) }).count < 2 { continue }
            if kind == "POINT" {
                // It tends to go through the articles in turn, saying the same again.
                let words = TodayNews.stems(body)
                guard (sections[kind]?.count ?? 0) < 6, !said.contains(where: { $0.intersection(words).count * 5 >= words.count * 3 }) else { continue }
                said.append(words)
            }
            let numbers = (before + "," + after).matches(of: /\d+/).map { String($0.0) }
            sections[kind, default: []].append("- \(opening)[[\(numbers.isEmpty ? allOfThem : numbers.joined(separator: ","))]]")
        }
        // Nothing whole yet: empty, so the screen goes on saying it's working.
        guard gist != nil || !sections.isEmpty else { return "" }
        var lines = ["@ article"]
        if let gist { lines.append("> \(gist)") }
        for (kind, heading, icon) in [("POINT", story, "news"), ("DIFF", differ, "compare")] {
            if let points = sections[kind] { lines += ["## [\(icon)] \(heading)"] + points }
        }
        return lines.joined(separator: "\n")
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
