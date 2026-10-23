import SwiftUI

/// Full-screen summary. It opens on the page itself, which shrinks into a card
/// at the top (from wherever a pinch left it); a light passes down the card
/// while it's read, then the summary writes itself below. Closing plays it
/// backwards: the card grows into the page again.
struct SummaryView: View {
    @Environment(BrowserModel.self) private var browser
    let model: SummaryModel

    /// False: the card fills the screen as the page did. True: it's the card.
    @State private var settled = false
    private let cardHeight: CGFloat = 210

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Theme.canvas
                    .opacity(settled ? 1 : 0)
                    .ignoresSafeArea()

                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            card(width: proxy.size.width)
                                .id("card")
                            content
                                .opacity(settled ? 1 : 0)
                                .offset(y: settled ? 0 : 40)
                                // Out quickly on close, so only the card is moving.
                                .animation(settled ? nil : .easeOut(duration: 0.15), value: settled)
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollDisabled(!settled)
                    .scrollIndicators(.hidden)
                    .onChange(of: settled) { _, isSettled in
                        // Closing from further down: the card returns to the top as it grows.
                        if !isSettled { scroller.scrollTo("card", anchor: .top) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .opacity(settled ? 1 : 0)
            }
        }
        .sensoryFeedback(.success, trigger: model.phase == .done)
        .onAppear {
            // The card now sits exactly where the page was: hide the page.
            browser.summaryCoversPage = true
            withAnimation(.spring(duration: 0.6, bounce: 0.16)) { settled = true }
        }
    }

    // MARK: The page, becoming a card

    private func card(width: CGFloat) -> some View {
        let image = model.snapshot
        let fullHeight = image.map { width * $0.size.height / max($0.size.width, 1) } ?? cardHeight
        let scale = settled ? 1 : model.startScale
        let inset: CGFloat = settled ? 22 : 0
        return VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width - inset * 2, height: settled ? cardHeight : fullHeight, alignment: .top)
                        .clipped()
                } else {
                    Theme.raised.frame(height: cardHeight)
                }
                if settled, model.phase == .reading || (model.phase == .writing && model.text.isEmpty) {
                    ScanLight()
                }
            }
            .clipShape(.rect(cornerRadius: settled ? 24 : 40 * (1 - scale)))
            .overlay {
                RoundedRectangle(cornerRadius: settled ? 24 : 0).strokeBorder(Theme.edge.opacity(settled ? 1 : 0))
            }
            .scaleEffect(scale, anchor: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(model.host)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .opacity(settled ? 1 : 0)
        }
        .padding(.horizontal, inset)
        .padding(.top, settled ? 12 : 0)
    }

    // MARK: The summary

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.phase {
            case .reading:
                StatusLine(text: "Reading the page", font: .system(size: 20))
            case .failed(let message):
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryInk)
            case .writing, .done:
                if model.text.isEmpty {
                    StatusLine(text: "Writing the summary", font: .system(size: 20))
                } else {
                    MarkdownText(markdown: model.text, isStreaming: model.phase == .writing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    /// Who wrote it, and the way back to the page, always in reach.
    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.phase == .done ? Self.credit(model.engine) + (model.note.map { " · \($0)" } ?? "") : "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintInk)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: close) {
                Glyph(.close, size: 16, weight: 2)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("Back to the page")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.canvas)
    }

    private func close() {
        // The page comes back underneath, full size, as the card grows into it.
        browser.summaryCoversPage = false
        withAnimation(.spring(duration: 0.5, bounce: 0.05)) { settled = false } completion: {
            browser.summary = nil
        }
    }

    private static func credit(_ engine: String) -> String {
        switch engine {
        case "Claude": "Summarized by Claude"
        case "Apple Intelligence": "Summarized by Apple Intelligence, privately in Apple's cloud"
        default: "Summarized on this iPhone"
        }
    }
}

/// A soft band of light travelling down the page card: the page is being read.
private struct ScanLight: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: proxy.size.height * 0.45)
                    .offset(y: (phase * 1.45 - 0.45) * proxy.size.height)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
