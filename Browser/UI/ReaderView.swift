import SwiftUI
import WebKit

/// The article alone: Readability's extracted text set for reading.
@Observable
final class ReaderModel: Identifiable {
    let host: String
    /// A story from the feed, which has no tab behind it: its picture and
    /// headline show at once, and it can be saved or opened as a page.
    let story: NewsStory?
    private(set) var page: ReadablePage? {
        didSet { paragraphs = page.map(Self.paragraphs(of:)) ?? [] }
    }
    /// The page's text to show, with its links on.
    private(set) var paragraphs: [AttributedString] = []
    private(set) var failure: String?
    /// A story's three sides: its text, its summary, and the page it came from.
    enum Side { case reader, summary, page }
    private(set) var side = Side.reader
    /// The page has been asked for, so its web view stays, keeping its place.
    private(set) var pageOpened = false
    /// Written the first time it's asked for, and kept while the article's open.
    private(set) var summary: SummaryModel?
    /// Whether Summary is on offer. Nothing says beforehand what Apple's guardrails
    /// will turn down, and trying on every story would cost battery for summaries
    /// nobody asked for. So it's tried when tapped; if it can't be written it says
    /// so, and the choice goes once you leave, for this story from then on.
    private(set) var offersSummary: Bool
    private static let worthSummarizing = 600

    init(host: String, story: NewsStory? = nil) {
        self.host = host
        self.story = story
        let someModel = ClaudeClient.configured != nil || AppleModels.cloudIfAvailable != nil || OnDeviceSummarizer.isAvailable
        offersSummary = someModel && story.map { FeedStore.shared.canSummarize($0.link) || ClaudeClient.configured != nil } ?? false
    }

    func load() async {
        guard let story else { return }
        if let found = await FeedStore.shared.readable(story) {
            page = found
            // A couple of lines, a confirmation mail say: already as short as a summary.
            if found.text.count < Self.worthSummarizing { offersSummary = false }
            if !found.isArticle { show(.page) }
            if side == .summary { startSummary() }
        } else {
            failure = "Couldn't read this article here."
            offersSummary = false
            show(.page)
        }
    }

    func show(_ wanted: Side) {
        side = wanted
        if wanted == .page { pageOpened = true }
        if wanted == .summary { startSummary() }
    }

    private func startSummary() {
        guard summary == nil, let page, let story else { return }
        let model = SummaryModel(title: story.title, host: story.host, snapshot: nil)
        summary = model
        model.start(page: page, url: story.link)
        Task {
            await model.finished()
            guard model.phase.isFailure else { return }
            FeedStore.shared.noteNoSummary(for: story.link)
            withAnimation(.snappy(duration: 0.28)) { offersSummary = false }
        }
    }

    func load(from webView: WKWebView) async {
        do {
            page = try await PageReader.read(webView)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Each link goes where it was: in its own paragraph, whole words only, so
    /// "here" doesn't land inside "where". One that knows no paragraph goes on the
    /// first place it's said. Then addresses written out; a bare "index.hr" in a
    /// sentence stays a word.
    private static func paragraphs(of page: ReadablePage) -> [AttributedString] {
        let lines = page.text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var result = lines.map { AttributedString($0) }
        func put(_ url: URL, on range: Range<String.Index>, line: Int) -> Bool {
            guard let range = Range(range, in: result[line]), result[line][range].runs.allSatisfy({ $0.link == nil }) else { return false }
            result[line][range].link = url
            result[line][range].underlineStyle = .single
            return true
        }
        func place(_ link: PageLink, line: Int) -> Bool {
            let text = lines[line]
            let whole = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: link.words) + #"(?![\p{L}\p{N}])"#
            var from = text.startIndex
            while let range = text.range(of: whole, options: .regularExpression, range: from..<text.endIndex) {
                if put(link.url, on: range, line: line) { return true }
                from = range.upperBound
            }
            return false
        }
        let linesOfText = Dictionary(grouping: lines.indices) { lines[$0] }
        for link in page.links {
            let lineNumbers = link.block.map { linesOfText[$0] ?? [] } ?? Array(lines.indices)
            _ = lineNumbers.first { place(link, line: $0) }
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for (line, text) in lines.enumerated() {
            for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                guard let url = match.url, url.scheme == "http" || url.scheme == "https", let range = Range(match.range, in: text) else { continue }
                let written = text[range].lowercased()
                if written.hasPrefix("http") || written.hasPrefix("www.") { _ = put(url, on: range, line: line) }
            }
        }
        return result
    }
}

struct ReaderView: View {
    @Environment(BrowserModel.self) private var browser
    @Namespace private var switchSpace
    let model: ReaderModel

    var body: some View {
        ZStack {
            article.opacity(model.side == .page ? 0 : 1)
            if model.pageOpened, let story = model.story {
                ArticlePage(url: story.link, html: story.isMail ? Newsletters.original(of: story.link) : nil, openLink: browser.openPage)
                    .opacity(model.side == .page ? 1 : 0)
                    .allowsHitTesting(model.side == .page)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let story = model.story { storyBar(story) }
        }
        .onDisappear { model.summary?.cancel() }
        .presentationDetents([.large])
        .presentationBackground(Theme.panel)
        .presentationCornerRadius(28)
    }

    private var article: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.side == .summary, let story = model.story {
                    summaryBody(story)
                } else if let page = model.page, !page.isArticle {
                    Text("Nothing to read here")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Reader Mode works on articles and posts. This page looks like a homepage or a list of links.")
                        .foregroundStyle(Theme.secondaryInk)
                } else if let page = model.page {
                    storyPicture
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.title)
                            .font(.system(.title, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(page.site.isEmpty ? model.host : page.site)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                        }
                    .padding(.bottom, 6)

                    ForEach(Array(model.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 19))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.ink)
                            .tint(Theme.ink)
                            .textSelection(.enabled)
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        browser.openPage(url)
                        return .handled
                    })
                    if let leave = model.story?.unsubscribe {
                        Button("Unsubscribe") { browser.openPage(leave) }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(minHeight: 44)
                    }
                } else if let failure = model.failure {
                    Text(failure).foregroundStyle(Theme.secondaryInk)
                } else {
                    if let story = model.story {
                        storyPicture
                        Text(story.title)
                            .font(.system(.title, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    StatusLine(text: "Preparing the article")
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 60)
        }
    }

    /// The feed's picture, in a shape of its own, so the text doesn't move when it arrives.
    @ViewBuilder
    private var storyPicture: some View {
        if let story = model.story, story.image != nil {
            Theme.raised
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { FeedPicture(story: story, isLarge: true) }
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.edge))
                .accessibilityHidden(true)
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summaryBody(_ story: NewsStory) -> some View {
        Text(story.title)
            .font(.system(.title2, weight: .semibold))
            .foregroundStyle(Theme.ink)
        if let summary = model.summary, !summary.isWorking {
            if case .failed(let message) = summary.phase {
                Text(message).foregroundStyle(Theme.secondaryInk)
            } else {
                MarkdownText(markdown: summary.text, isStreaming: summary.phase == .writing, anchor: "reader-summary")
                if summary.phase == .done {
                    Text([credit(summary.engine), summary.readingTime, summary.note].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faintInk)
                }
            }
        } else if let failure = model.failure {
            Text(failure).foregroundStyle(Theme.secondaryInk)
        } else {
            StatusLine(text: model.page == nil ? "Preparing the article" : "Writing the summary")
        }
    }

    private func credit(_ engine: String) -> String {
        switch engine {
        case "Claude": "Written by Claude"
        case "Apple Intelligence": "Written by Apple Intelligence, privately in Apple's cloud"
        default: "Written on this iPhone"
        }
    }

    // MARK: The bar

    /// Always in reach: the story's three sides, one switch. Beside them, put it
    /// aside, or take the page into a tab of its own.
    private func storyBar(_ story: NewsStory) -> some View {
        let saved = ReadLater.shared.contains(story.link)
        return HStack(spacing: 0) {
            // A newsletter has no address to save or open: its text and its email are here.
            if story.isMail {
                Color.clear.frame(width: 52, height: Theme.barHeight)
            } else {
                barButton(.readLater, label: saved ? "Saved to Read Later" : "Save to Read Later", tint: saved ? Theme.accentText : Theme.ink) {
                    ReadLater.shared.save(story, text: model.page?.text ?? "")
                }
                .disabled(saved)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                switchWord("Reader", isOn: model.side == .reader) { model.show(.reader) }
                if model.offersSummary || model.side == .summary {
                    switchWord("Summary", isOn: model.side == .summary) { model.show(.summary) }
                }
                switchWord(story.isMail ? "Email" : "Page", isOn: model.side == .page) { model.show(.page) }
            }
            Spacer(minLength: 0)
            if story.isMail {
                Color.clear.frame(width: 52, height: Theme.barHeight)
            } else {
                barButton(.openLink, label: "Open in a tab", tint: Theme.ink) { browser.openOriginal(of: story) }
            }
        }
        .frame(height: Theme.barHeight + 8)
        .barSurface(cornerRadius: Theme.barRadius)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Theme.panel)
        .background(alignment: .top) {
            if model.side != .page { FadeEdge(color: Theme.panel) }
        }
    }

    private func switchWord(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Theme.ink : Theme.secondaryInk)
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background {
                    if isOn { Capsule().fill(Theme.raised).matchedGeometryEffect(id: "side", in: switchSpace) }
                }
                .frame(height: Theme.barHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func barButton(_ glyph: Glyph.Kind, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: 18)
                .foregroundStyle(tint)
                .frame(width: 52, height: Theme.barHeight)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }
}

/// The story's own page, in place: it stays as it is while the others show.
/// Its links open here, a new window's too: this isn't a tab. A newsletter's go to
/// a tab: scripts are off in here, and the page they lead to may need them.
private struct ArticlePage: UIViewRepresentable {
    let url: URL
    /// A newsletter's original, in place of the address: its images load, its scripts don't run.
    var html: String?
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openLink: html == nil ? nil : openLink) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WebViewFactory.makeOffscreen()
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let html {
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            // A mail's first line starts at the top: clear of the sheet's rounded corners.
            webView.scrollView.contentInset.top = 20
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        private let openLink: ((URL) -> Void)?

        init(openLink: ((URL) -> Void)?) {
            self.openLink = openLink
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let openLink, let url = navigationAction.request.url {
                openLink(url)
            } else {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let openLink, navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                openLink(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
