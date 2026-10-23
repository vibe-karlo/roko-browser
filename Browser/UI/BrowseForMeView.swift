import SwiftUI

/// A page written for one question, from several sources read on your behalf.
/// While it works, it shows the work: your question, then each site as it is
/// read. Then the answer, with its sources and pictures up front.
struct BrowseForMeView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let model: BrowseForMeModel

    private var isWorking: Bool {
        switch model.phase {
        case .searching, .reading: true
        case .writing: model.text.isEmpty
        case .done, .failed: false
        }
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(model.query)
                    .id("top")
                    .font(.system(size: isWorking ? 30 : 17, weight: .semibold))
                    .foregroundStyle(isWorking ? Theme.ink : Theme.secondaryInk)
                    .lineLimit(isWorking ? 4 : 2)
                    .padding(.top, isWorking ? 24 : 0)

                if isWorking {
                    working
                } else if case .failed(let message) = model.phase {
                    Text(message).foregroundStyle(Theme.secondaryInk)
                } else {
                    if !model.sources.isEmpty { sources }
                    if !model.images.isEmpty { pictures }
                    MarkdownText(markdown: model.text, isStreaming: model.phase == .writing)
                }
            }
            .animation(.snappy(duration: 0.4), value: isWorking)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        // When the answer replaces the reading list, start at its top.
        .onChange(of: isWorking) { _, working in
            if !working { scroller.scrollTo("top", anchor: .top) }
        }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .sensoryFeedback(.success, trigger: model.phase == .done)
        .presentationDetents([.large])
        .presentationBackground(Theme.panel)
        .presentationCornerRadius(28)
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
                            .opacity(step.state == .reading ? 0.45 : 1)
                        Text(step.url.displayHost)
                            .font(.system(size: 17))
                            .foregroundStyle(step.state == .read ? Theme.ink : Theme.faintInk)
                            .strikethrough(step.state == .skipped, color: Theme.faintInk)
                        if step.state == .read {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                .transition(.scale.combined(with: .opacity))
                        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: -5) {
                    ForEach(model.sources.prefix(6)) { source in
                        SiteIcon(host: source.url.displayHost, size: 18, remote: true)
                            .padding(2)
                            .background(Theme.panel, in: .rect(cornerRadius: 6))
                    }
                }
                Text("Read \(model.sources.count) \(model.sources.count == 1 ? "page" : "pages")")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryInk)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.sources) { source in
                        Button { open(source.url) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(source.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    SiteIcon(host: source.url.displayHost, size: 14, remote: true)
                                    Text(source.url.displayHost)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineLimit(1)
                                }
                            }
                            .padding(14)
                            .frame(width: 190, alignment: .leading)
                            .background(Theme.raised, in: .rect(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.edge))
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
                    .frame(width: 200, height: 130)
                    .clipShape(.rect(cornerRadius: 16))
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.phase == .done {
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
            }
            Text(credit)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button { dismiss() } label: {
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
        .background(Theme.panel)
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
