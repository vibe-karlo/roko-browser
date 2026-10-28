import SwiftUI

/// Summarize all: one page across everything unread in Read Later, built like
/// a Browse for Me answer. The saved pages first, numbered as the marks in the
/// text are, then the summary by theme; each mark opens its page. While it's
/// written, roko's light rises behind it.
struct DigestView: View {
    @Environment(BrowserModel.self) private var browser
    let model: DigestModel
    @State private var readProgress = 0.0
    /// No canvas under the footer or the status bar while the light is up and
    /// on through its flood (as in Browse for Me).
    @State private var edgesClear = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heading
                    .padding(.top, model.isWorking ? 24 : 0)
                pages
                if model.isWorking {
                    StatusLine(text: statusText, font: .system(size: 20, weight: .medium))
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else if case .failed(let message) = model.phase {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(message).foregroundStyle(Theme.secondaryInk)
                        Button("Try again") { model.retry() }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .buttonStyle(.plain)
                    }
                } else {
                    MarkdownText(markdown: model.text, isStreaming: model.phase == .writing,
                                 sources: model.pages.map(\.url), openSource: open, anchor: "digest")
                        .transition(.opacity.combined(with: .offset(y: 16)))
                    if model.phase == .done {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            RokoSignature()
                            Text([credit, model.readingTime, model.note].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.faintInk)
                                .lineLimit(2)
                        }
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 24)
            .animation(.smooth(duration: 0.5), value: model.isWorking)
            .animation(.smooth(duration: 0.4), value: model.phase == .done)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulled in
            if pulled { close() }
        }
        .onScrollGeometryChange(for: Double.self) { ReadingLine.progress($0) } action: { _, progress in
            readProgress = progress
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas).opacity(edgesClear ? 0 : 1) }
        .background {
            ZStack {
                Theme.canvas
                WorkingGlow(progress: model.progress, isActive: model.isWorking,
                            finished: !model.isWorking && !model.phase.isFailure)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isModal)
        .sensoryFeedback(.success, trigger: model.phase == .done)
        .onAppear { edgesClear = model.isWorking }
        .onChange(of: model.isWorking) { _, working in
            if working {
                withAnimation(.easeInOut(duration: 0.9)) { edgesClear = true }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (model.phase.isFailure ? 0 : WorkingGlow.floodDuration)) {
                guard !model.isWorking else { return }
                withAnimation(.easeInOut(duration: 0.9)) { edgesClear = false }
            }
        }
    }

    /// Large while it's being written, quiet above the summary, as a question is in Browse for Me.
    private var heading: some View {
        Text(model.subject ?? (model.pages.count == 1 ? "1 saved page" : "\(model.pages.count) saved pages"))
            .font(.system(size: model.isWorking ? 30 : 17, weight: .semibold))
            .foregroundStyle(model.isWorking ? Theme.ink : Theme.secondaryInk)
    }

    private var statusText: String {
        switch model.phase {
        case .reading where model.condensed > 0: "Reading page \(min(model.condensed + 1, model.pages.count)) of \(model.pages.count)"
        case .reading: "Reading what you saved"
        default: "Writing the summary"
        }
    }

    /// The pages, numbered as their marks are, each opening the page.
    private var pages: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    Button { browser.openSaved(page) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(page.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 5) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(PageKind.of(model.text).tint)
                                SiteIcon(host: page.site, size: 12, remote: true)
                                Text(page.site)
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
                    .accessibilityLabel("Page \(index + 1): \(page.title), \(page.site)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var footer: some View {
        ContextBar(leading: .init(glyph: .close, label: "Close", action: close),
                   glyph: .browse, title: "Ask",
                   launch: { browser.showCommandBar(context: .aboutSaved, over: .readLater) },
                   fades: false)
            .padding(.top, 10)
            .overlay(alignment: .top) { ReadingLine(progress: readProgress, tint: PageKind.of(model.text).tint) }
            .background(Theme.canvas.opacity(edgesClear ? 0 : 1))
            .background(alignment: .top) { FadeEdge(color: Theme.canvas).opacity(edgesClear ? 0 : 1) }
    }

    private var credit: String? {
        switch model.engine {
        case "Claude": "Written by Claude"
        case "Apple Intelligence": "Written by Apple Intelligence, privately in Apple's cloud"
        default: "Written on this iPhone"
        }
    }

    private func open(_ url: URL) {
        guard let page = model.pages.first(where: { $0.url == url }) else { return }
        browser.openSaved(page)
    }

    private func close() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { browser.digest = nil }
    }
}
