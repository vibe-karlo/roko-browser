import FoundationModels
import UIKit
import WebKit

/// The shape every AI answer takes, so the app can lay it out as a page:
/// a lead line, then a few sections each tagged with a topic the app draws as an icon.
private let answerShape = """
Format, in Markdown (angle brackets mark what you write):

> <the gist, one or two sentences>
## [<topic>] <heading for this answer>
<one or two short sentences>
## [<topic>] <heading for this answer>
- **<key term>:** <detail>
- **<key term>:** <detail>

Rules: one "> " line with the gist. Then three to five "## " sections with headings written for \
this answer. The word in brackets only chooses the section's icon: pick the closest from \
[\(AnswerTopic.vocabulary)], and use each at most once. Under each heading, one or two short \
sentences or two to four "- " lines. No emoji. No preamble, no sign-off.
"""

private let summaryGuidance = """
You summarize web pages for a phone browser. Write in the page's own language. \
Only facts from the page. No preamble, no sign-off.
"""

private let summaryInstructions = summaryGuidance + "\n" + answerShape

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

    func run(webView: WKWebView) async {
        do {
            let page = try await PageReader.read(webView)
            phase = .writing

            // Best available first: Apple's cloud model, then on-device, then Claude.
            if let cloud = AppleModels.cloudIfAvailable {
                do {
                    engine = "Apple Intelligence"
                    let budget = await AppleModels.characterBudget(of: cloud)
                    if page.text.count > budget { note = "Long page: this covers the first part." }
                    let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text.prefix(budget))"
                    for try await snapshot in AppleModels.streamAnswer(cloud, instructions: summaryGuidance, prompt: prompt, titled: false) {
                        text = snapshot
                    }
                    phase = .done
                    return
                } catch is CancellationError {
                    return
                } catch {
                    // Quota reached, offline, or service busy: try the next engine.
                    text = ""
                    note = nil
                }
            }

            if OnDeviceSummarizer.isAvailable {
                engine = "On-device"
                do {
                    let (stream, truncated) = OnDeviceSummarizer.summarize(page)
                    if truncated { note = "Long page: this covers the first part." }
                    for try await snapshot in stream { text = snapshot }
                    phase = .done
                    return
                } catch where ClaudeClient.configured != nil {
                    text = ""
                    note = nil
                    // Fall through to Claude when the small on-device model can't cope.
                }
            }

            guard let client = ClaudeClient.configured else {
                throw ClaudeError(message: "Summaries need Apple Intelligence on this iPhone, or a Claude API key in Settings.")
            }
            engine = "Claude"
            let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(page.text)"
            for try await event in client.stream(system: summaryInstructions, prompt: prompt, effort: "low", webSearch: false) {
                if case .text(let chunk) = event { text += chunk }
            }
            phase = .done
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
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
                                instructions: "List the key facts in this part of a web page as three to five short lines starting with \"- \". Nothing else.")
                            notes.append(try await session.respond(to: chunk).content)
                        }
                        material = notes.joined(separator: "\n")
                    }

                    let prompt = "Title: \(page.title)\nSite: \(page.site)\n\n\(material)"
                    for try await markdown in AppleModels.streamAnswer(SystemLanguageModel.default, instructions: summaryGuidance,
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
    private(set) var text = ""
    private(set) var sources: [Source] = []
    private(set) var steps: [Step] = []
    /// Pictures from the sources, shown above the answer.
    private(set) var images: [URL] = []
    private(set) var phase: Phase = .searching("")
    private(set) var engine = ""

    init(query: String) {
        self.query = query
    }

    private static let format = """
    Write a compact answer page. First line: "# " and a specific title. Lead with what the \
    person most likely wants to know. Don't list the sources (the app shows them).
    """ + answerShape

    private static let claudeInstructions = """
    You are the "Browse for Me" feature of a phone browser. Search the web, read several \
    trustworthy sources, then answer. 
    """ + format

    private static let appleInstructions = """
    You are the "Browse for Me" feature of a phone browser. The app has searched the web and \
    read the pages below for you. Answer the question using only these sources. Where they \
    disagree, say so; if they don't answer part of the question, say what is missing. Write in \
    the language of the question. Lead with what the person most likely wants to know.
    """

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
            let candidates = Array(results.prefix(6))
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

            var prompt = "Question: \(query)\n\nSources:\n"
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
            for try await snapshot in AppleModels.streamAnswer(model, instructions: Self.appleInstructions, prompt: prompt) {
                text = snapshot
            }
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
            for try await event in client.stream(system: Self.claudeInstructions, prompt: query, effort: "medium", webSearch: true) {
                switch event {
                case .searching(let query):
                    phase = .searching(query)
                case .source(let source):
                    if !sources.contains(where: { $0.url.displayHost == source.url.displayHost }) {
                        sources.append(source)
                        steps.append(Step(url: source.url, state: .read))
                    }
                case .text(let chunk):
                    text += chunk
                    phase = .writing
                }
            }
            phase = .done
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The topics a section can be tagged with; each is a Phosphor icon in the assets.
nonisolated enum AnswerTopic {
    static let all = ["idea", "check", "warning", "money", "time", "place", "people", "privacy", "speed", "star",
                      "trend", "learn", "health", "tools", "world", "list", "question", "date", "battery", "device",
                      "code", "nature", "food", "quote", "travel", "sport", "law", "news", "compare", "settings"]
    static let vocabulary = all.joined(separator: ", ")
}
