import SwiftUI

/// A page written for one question, from several sources read on your behalf.
/// While it works, it shows the work: your question, then each site as it is
/// read. Then the answer, with its sources and pictures up front.
///
/// Full screen, like Summarize, on the same plain canvas: it's for reading.
/// Its one flourish has a job: when the answer arrives, the icons of the sites
/// it read fly up into the row of sources, so the list visibly becomes them.
struct BrowseForMeView: View {
    @Environment(BrowserModel.self) private var browser
    let model: BrowseForMeModel
    /// Pairs each site's icon in the reading list with the same icon in the source row.
    @Namespace private var icons
    /// Rewording the question, in place.
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isWorking: Bool {
        switch model.phase {
        case .searching, .reading: true
        case .writing: model.text.isEmpty
        case .done, .failed: false
        }
    }

    var body: some View {
        // No scrolling to the top when the answer arrives: the view is already
        // there, and in full screen scrollTo pulled the question under the status bar.
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                question
                    .padding(.top, isWorking ? 24 : 0)

                if isWorking {
                    working
                } else if case .failed(let message) = model.phase {
                    Text(message).foregroundStyle(Theme.secondaryInk)
                } else {
                    // Pictures first, then the sources: the faces of the answer
                    // up top, its footnotes compact beneath them.
                    if !model.images.isEmpty { pictures }
                    if !model.sources.isEmpty { sources }
                    MarkdownText(markdown: model.answer, isStreaming: model.phase == .writing)
                    if !model.followUps.isEmpty { followUps }
                }
            }
            .animation(.snappy(duration: 0.4), value: isWorking)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        // Pulling down past the top closes it, as the sheet it replaces did.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulledPastTop in
            if pulledPastTop { close() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isModal)
        .sensoryFeedback(.success, trigger: model.phase == .done)
    }

    private func close() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { browser.browseForMe = nil }
    }

    // MARK: The question

    /// The question, large while it's being worked on and quiet above the
    /// answer. Tap it to reword it; Return asks again.
    @ViewBuilder
    private var question: some View {
        let font = Font.system(size: isWorking ? 30 : 17, weight: .semibold)
        if editing {
            TextField("Ask anything", text: $draft)
                .font(font)
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .focused($fieldFocused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .onSubmit(ask)
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { _, focused in if !focused { editing = false } }
        } else {
            Button {
                draft = model.query
                editing = true
            } label: {
                Text(model.query)
                    .font(font)
                    .foregroundStyle(isWorking ? Theme.ink : Theme.secondaryInk)
                    .lineLimit(isWorking ? 4 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Edit the question")
        }
    }

    private func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !question.isEmpty, question != model.query else { return }
        browser.browse(for: question)
    }

    // MARK: Follow-ups

    /// What to ask next, when the answer suggests it. Each opens a new answer.
    private var followUps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.followUps, id: \.self) { question in
                Button { browser.browse(for: question) } label: {
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

    // MARK: Working

    /// "Reading 6 pages", then the sites one by one, lighting up as each is read.
    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusLine(text: statusText, font: .system(size: 20, weight: .medium))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.steps) { step in
                    HStack(spacing: 12) {
                        SiteIcon(host: step.url.displayHost, size: 18, remote: true)
                            .matchedGeometryEffect(id: step.url.absoluteString, in: icons)
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
            .animation(.easeOut(duration: 0.3), value: model.steps)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .searching(let query): query.isEmpty || query == model.query ? "Searching the web" : "Searching \u{201C}\(query)\u{201D}"
        case .reading(let count): "Reading \(count) web pages"
        default: "Writing your answer"
        }
    }

    // MARK: Answer

    /// The sites behind the answer: their icons in a row, then cards to open each.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: -5) {
                    ForEach(model.sources.prefix(6)) { source in
                        // Arrives from its place in the reading list.
                        SiteIcon(host: source.url.displayHost, size: 18, remote: true)
                            .matchedGeometryEffect(id: source.url.absoluteString, in: icons)
                            .padding(2)
                            .background(Theme.canvas, in: .rect(cornerRadius: 6))
                    }
                }
                // The pages the answer rests on, not every search hit along the way.
                Text("Based on \(model.sources.count) \(model.sources.count == 1 ? "page" : "pages")")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryInk)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.sources) { source in
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
                ForEach(model.images, id: \.self) { url in
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Theme.raised
                        }
                    }
                    .frame(width: 240, height: 160)
                    .clipShape(.rect(cornerRadius: 18))
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // From the start, not only once the answer is in: if it's taking
            // long, the search engine is one tap away (and the answer stops).
            Button {
                open(SearchEngine.current.searchURL(for: model.query))
            } label: {
                HStack(spacing: 8) {
                    Glyph(.search, size: 15)
                    Text(SearchEngine.current.name).font(.system(size: 15, weight: .medium))
                }
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Theme.raised, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("Search \(SearchEngine.current.name) instead")
            Text(credit)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button(action: close) {
                Glyph(.close, size: 16, weight: 2)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.canvas)
        .background(alignment: .top) { FadeEdge(color: Theme.canvas) }
    }

    private var credit: String {
        guard model.phase == .done else { return "" }
        switch model.engine {
        case "Claude": return "By Claude"
        case "Apple Intelligence": return "By Apple Intelligence"
        default: return "Written on this iPhone"
        }
    }

    private func open(_ url: URL) {
        browser.browseForMe = nil
        browser.open(url, inNewTab: true)
    }
}
