import SwiftUI
import WebKit

/// A page written for a question, from several sources read on your behalf,
/// that grows as you ask follow-ups: each is a new section below the last,
/// answered with the page so far in mind. While a section is being worked on
/// it shows the work (each site as it's read, over a warm light that rises as
/// they are), then the answer with its pictures and sources.
///
/// Full screen, like Summarize. A switch at the bottom flips the whole page to
/// the search engine's results for the latest question and back, losing nothing.
struct BrowseForMeView: View {
    @Environment(BrowserModel.self) private var browser
    @Bindable var session: BrowseSession
    /// Pairs each site's icon in a reading list with the same icon in its source row.
    @Namespace private var icons
    @State private var viewportHeight: CGFloat = 0
    /// No canvas under the footer or the status bar: while the light is up,
    /// and on through its flood when an answer arrives. Set here, not worked
    /// out from the answer's state, so it never flickers solid for the frame
    /// between the work ending and the flood starting.
    @State private var edgesClear = true

    private var latest: BrowseForMeModel { session.latest }

    var body: some View {
        ZStack {
            answers
                .opacity(session.showsSearch ? 0 : 1)
                .allowsHitTesting(!session.showsSearch)
            if session.showsSearch, let webView = session.searchView {
                SearchResults(webView: webView)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.showsSearch)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay(alignment: .top) {
            StatusBarFade(color: Theme.canvas).opacity(session.showsSearch || edgesClear ? 0 : 1)
        }
        .background { background }
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isModal)
        .sensoryFeedback(.success, trigger: latest.phase == .done)
        .onAppear { edgesClear = latest.isWorking }
        .onChange(of: latest.isWorking) { _, working in
            if working {
                withAnimation(.easeInOut(duration: 0.9)) { edgesClear = true }
                return
            }
            // A flood first, when the answer arrived; otherwise at the light's own pace.
            let flooded = !session.showsSearch && !latest.phase.isFailure
            DispatchQueue.main.asyncAfter(deadline: .now() + (flooded ? WorkingGlow.floodDuration : 0)) {
                guard !latest.isWorking else { return }
                withAnimation(.easeInOut(duration: 0.9)) { edgesClear = false }
            }
        }
    }

    /// The canvas, and while the latest question is being worked on, the light.
    private var background: some View {
        ZStack {
            Theme.canvas
            // Always in place; it rises and sinks by itself as work starts and ends.
            WorkingGlow(progress: latest.progress, isActive: latest.isWorking && !session.showsSearch,
                        finished: !latest.isWorking && !session.showsSearch && !latest.phase.isFailure)
        }
        .ignoresSafeArea()
    }

    // MARK: Answers

    private var answers: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.turns.enumerated()), id: \.element.id) { index, turn in
                        // Where a new section is scrolled to.
                        Color.clear.frame(height: 0).id(ObjectIdentifier(turn))
                        TurnSection(turn: turn, isLatest: index == session.turns.count - 1, icons: icons,
                                    reword: { session.reask(turn, as: $0) },
                                    ask: { session.ask($0) },
                                    open: open)
                            .padding(.top, index == 0 ? 0 : 56)
                            // A follow-up's section is at least a screen tall, so it can
                            // come up to the top while it's still only a question.
                            .frame(minHeight: index > 0 && index == session.turns.count - 1 ? viewportHeight : nil,
                                   alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 24)
            }
            // A follow-up's section comes into view just under the status bar.
            // (Not anchor .top: in full screen that's under the status bar.)
            .onChange(of: session.turns.count) { old, new in
                guard new > old else { return }
                withAnimation(.snappy(duration: 0.45)) {
                    scroller.scrollTo(ObjectIdentifier(latest), anchor: UnitPoint(x: 0.5, y: 0.09))
                }
            }
            // Pulling down past the top closes it, as the sheet it replaces did.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y < -geometry.contentInsets.top - 90
            } action: { _, pulledPastTop in
                if pulledPastTop { close() }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                viewportHeight = height
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            // The page's own line: signed for screenshots, and AI or the search engine's results.
            HStack(spacing: 12) {
                RokoSignature()
                Spacer(minLength: 8)
                AnswerOrSearch(showsSearch: $session.showsSearch)
            }
            .padding(.horizontal, 22)
            // The app's bar, for an answer: a follow-up from its middle, share beside it.
            ContextBar(leading: .init(glyph: .close, label: "Close", action: close),
                       glyph: .browse, title: "Ask a follow-up",
                       launch: { browser.showCommandBar(context: .followUp) }, 
                       trailing: AnswerSharing.isAvailable && session.turns.contains(where: { $0.phase == .done })
                           ? .init(glyph: .share, label: "Share this page", action: share) : nil,
                       fades: false)
        }
        .padding(.top, 6)
        // See-through while the light is up, so its brightest part shows.
        // It turns solid at the light's own pace, so no dark band crosses the light as it sinks.
        .background(Theme.canvas.opacity(edgesClear && !session.showsSearch ? 0 : 1))
        .background(alignment: .top) {
            FadeEdge(color: Theme.canvas).opacity(edgesClear || session.showsSearch ? 0 : 1)
        }
    }

    private func close() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { browser.browseForMe = nil }
    }

    /// Uploads the page (or its follow-ups since), then offers the link.
    private func share() {
        guard !session.isSharing else { return }
        session.isSharing = true
        Task {
            defer { session.isSharing = false }
            do {
                let url = try await AnswerSharing.share(session)
                ShareSheet.present([url])
            } catch {
                browser.showToast(error.localizedDescription)
            }
        }
    }

    private func open(_ url: URL) {
        browser.browseForMe = nil
        browser.open(url, inNewTab: true)
    }
}

/// Answer or search results, for the whole page. The selection slides between them.
private struct AnswerOrSearch: View {
    @Binding var showsSearch: Bool
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            // "AI" beside "Google": both name where the page comes from.
            segment(.browse, "AI", isOn: !showsSearch) { showsSearch = false }
                .accessibilityLabel("AI answer")
            segment(.search, SearchEngine.current.name, isOn: showsSearch) { showsSearch = true }
        }
        .padding(3)
        .background(Theme.raised, in: .capsule)
        .animation(.snappy(duration: 0.28), value: showsSearch)
        .sensoryFeedback(.selection, trigger: showsSearch)
    }

    private func segment(_ glyph: Glyph.Kind, _ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Glyph(glyph, size: 14)
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(isOn ? Theme.ink : Theme.secondaryInk)
            .fixedSize()
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background {
                if isOn {
                    Capsule().fill(Theme.ink.opacity(0.12))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The search engine's results, live: scroll, tap through, and flip back.
private struct SearchResults: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// One question on the page and its answer.
private struct TurnSection: View {
    let turn: BrowseForMeModel
    /// The last section: it gets the follow-ups.
    let isLatest: Bool
    let icons: Namespace.ID
    let reword: (String) -> Void
    let ask: (String) -> Void
    let open: (URL) -> Void

    /// Rewording the question, in place.
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    /// Pictures that wouldn't load.
    @State private var brokenImages: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            question
                .padding(.top, turn.isWorking ? 24 : 0)

            if turn.isWorking {
                // Out quickly, so nothing of it is left under the answer coming in.
                working
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else if case .failed(let message) = turn.phase {
                Text(message).foregroundStyle(Theme.secondaryInk)
            } else {
                // Pictures first, then the sources: the faces of the answer
                // up top, its footnotes compact beneath them. They arrive in
                // that order, a beat apart, each easing up into place.
                if turn.pendingPictures > 0 || !turn.images.allSatisfy(brokenImages.contains) {
                    pictures.transition(Self.reveal(0))
                }
                if !turn.sources.isEmpty { sources.transition(Self.reveal(1)) }
                MarkdownText(markdown: turn.answer, isStreaming: turn.phase == .writing)
                    .transition(Self.reveal(2))
                if !credit.isEmpty {
                    Text(credit)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faintInk)
                        .transition(.opacity)
                }
                if isLatest, !turn.followUps.isEmpty { followUps.transition(Self.reveal(1)) }
            }
        }
        .animation(.smooth(duration: 0.5), value: turn.isWorking)
        .animation(.smooth(duration: 0.4), value: turn.phase == .done)
    }

    /// The answer's parts coming in: up from a little below and out of nothing,
    /// one after another, once the reading list has gone. Leaving, they just fade.
    private static func reveal(_ order: Int) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16))
                .animation(.smooth(duration: 0.6).delay(0.16 + Double(order) * 0.1)),
            removal: .opacity)
    }

    // MARK: The question

    /// Large while it's being worked on, quiet above the answer. Tap it to
    /// reword it; Return asks again from there.
    @ViewBuilder
    private var question: some View {
        let font = Font.system(size: turn.isWorking ? 30 : 17, weight: .semibold)
        if editing {
            // Wraps like the question it replaces, instead of scrolling sideways on one line.
            TextField("Ask anything", text: $draft, axis: .vertical)
                .font(font)
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .lineLimit(1...4)
                .focused($fieldFocused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .onSubmit(submit)
                // A wrapping field takes Return as a new line: here it asks.
                .onChange(of: draft) { _, text in
                    if text.contains("\n") {
                        draft = text.replacingOccurrences(of: "\n", with: "")
                        submit()
                    }
                }
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { _, focused in if !focused { editing = false } }
        } else {
            Button {
                draft = turn.query
                editing = true
            } label: {
                Text(turn.query)
                    // Shrinks from the large question to the quiet heading as one
                    // smooth change of size, laid out afresh at every size between,
                    // rather than two sizes cross-fading over each other.
                    .modifier(AnimatedFontSize(size: turn.isWorking ? 30 : 17))
                    .contentTransition(.identity)
                    .foregroundStyle(turn.isWorking ? Theme.ink : Theme.secondaryInk)
                    .lineLimit(turn.isWorking ? 4 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Edit the question")
        }
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !question.isEmpty, question != turn.query else { return }
        reword(question)
    }

    // MARK: Working

    /// "Reading 6 pages", then the sites one by one, lighting up as each is read.
    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusLine(text: statusText, font: .system(size: 20, weight: .medium))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(turn.steps) { step in
                    HStack(spacing: 12) {
                        SiteIcon(host: step.url.displayHost, size: 18, remote: true)
                            .matchedGeometryEffect(id: iconID(step.url), in: icons)
                            .opacity(step.state == .reading ? 0.45 : 1)
                        // Read: the site lights up from faint to ink. Nothing tacked on beside it.
                        Text(step.url.displayHost)
                            .font(.system(size: 17))
                            .foregroundStyle(step.state == .read ? Theme.ink : Theme.faintInk)
                            .strikethrough(step.state == .skipped, color: Theme.faintInk)
                    }
                    .transition(.offset(y: 8).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: turn.steps)
        }
    }

    private var statusText: String {
        switch turn.phase {
        case .searching(let query): query.isEmpty || query == turn.query ? "Searching the web" : "Searching \u{201C}\(query)\u{201D}"
        case .reading(let count): "Reading \(count) web pages"
        default: "Writing your answer"
        }
    }

    /// Per section, so the same site in two sections flies to its own row.
    private func iconID(_ url: URL) -> String {
        "\(ObjectIdentifier(turn).hashValue)|\(url.absoluteString)"
    }

    // MARK: Answer

    /// The sites behind the answer: their icons in a row, then cards to open each.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: -5) {
                    ForEach(turn.sources.prefix(6)) { source in
                        // Arrives from its place in the reading list.
                        SiteIcon(host: source.url.displayHost, size: 18, remote: true)
                            .matchedGeometryEffect(id: iconID(source.url), in: icons)
                            .padding(2)
                            .background(Theme.canvas, in: .rect(cornerRadius: 6))
                    }
                }
                // The pages the answer rests on, not every search hit along the way.
                Text("Based on \(turn.sources.count) \(turn.sources.count == 1 ? "page" : "pages")")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryInk)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(turn.sources) { source in
                        Button { open(source.url) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 5) {
                                    SiteIcon(host: source.url.displayHost, size: 12, remote: true)
                                    Text(source.url.displayHost)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .frame(width: 164, alignment: .leading)
                            .background(Theme.raised, in: .rect(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.edge))
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    /// Pictures from the sources, so the answer has a face.
    private var pictures: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(turn.images.filter { !brokenImages.contains($0) }, id: \.self) { url in
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if case .failure = phase {
                            // Gone, rather than an empty tile for good.
                            Theme.raised.onAppear { brokenImages.insert(url) }
                        } else {
                            Theme.raised
                        }
                    }
                    .frame(width: 240, height: 160)
                    .clipShape(.rect(cornerRadius: 18))
                    .transition(.opacity)
                }
                // Still being looked for: their places, kept so the text below stays put.
                ForEach(0..<turn.pendingPictures, id: \.self) { _ in
                    Theme.raised
                        .frame(width: 240, height: 160)
                        .clipShape(.rect(cornerRadius: 18))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: brokenImages)
            .animation(.easeOut(duration: 0.3), value: turn.images)
            .animation(.easeOut(duration: 0.3), value: turn.pendingPictures)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    // MARK: Follow-ups

    /// What to ask next, when the answer suggests it. Each adds a section below.
    private var followUps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turn.followUps, id: \.self) { question in
                Button { ask(question) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Glyph(.browse, size: 15)
                            .foregroundStyle(Theme.secondaryInk)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text(question)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.raised, in: .rect(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.edge))
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    private var credit: String {
        guard turn.phase == .done else { return "" }
        switch turn.engine {
        case "Claude": return "By Claude"
        case "Apple Intelligence": return "By Apple Intelligence"
        default: return "Written on this iPhone"
        }
    }
}

/// A semibold system font whose size animates: SwiftUI asks for the body at
/// every size in between, so text grows or shrinks as one shape.
private struct AnimatedFontSize: ViewModifier, Animatable {
    var size: CGFloat
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .semibold))
    }
}
