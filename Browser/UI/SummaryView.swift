import SwiftUI

/// Full-screen summary. It opens on the page itself, which shrinks into a card
/// at the top; a light passes down the card
/// while it's read, then the summary writes itself below. Closing plays it
/// backwards: the card grows into the page again.
struct SummaryView: View {
    @Environment(BrowserModel.self) private var browser
    let model: SummaryModel

    /// False: the card fills the screen as the page did. True: it's the card.
    @State private var settled = false
    /// The title and summary show only once the card has come to rest.
    @State private var textShown = false
    /// No canvas under the footer or the status bar while the light is up and
    /// on through its flood. Set here, so it never flickers solid for the frame
    /// between the light going and the flood starting.
    @State private var edgesClear = false
    private let cardHeight: CGFloat = 210

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Theme.canvas
                    .opacity(settled ? 1 : 0)
                    .ignoresSafeArea()

                // roko's light while it works: rising as the page is read, flooding
                // the screen as the summary starts. Not while the card is still moving.
                if textShown {
                    WorkingGlow(progress: model.progress, isActive: showsLight,
                                finished: !model.isWorking && !model.isClosing && !model.phase.isFailure)
                        .ignoresSafeArea()
                }

                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            card(width: proxy.size.width)
                                .id("card")
                            content
                                .opacity(textShown ? 1 : 0)
                                .offset(y: textShown || model.isClosing ? 0 : 12)
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
                    .opacity(textShown ? 1 : 0)
            }
            // Only once settled: while opening and closing, the page card owns the top.
            .overlay(alignment: .top) {
                StatusBarFade(color: Theme.canvas).opacity(textShown && !edgesClear ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showsLight)
        .sensoryFeedback(.success, trigger: model.phase == .done)
        .onChange(of: showsLight) { _, lit in
            if lit {
                withAnimation(.easeInOut(duration: 0.9)) { edgesClear = true }
                return
            }
            let flooded = !model.isClosing && !model.phase.isFailure
            DispatchQueue.main.asyncAfter(deadline: .now() + (flooded ? WorkingGlow.floodDuration : 0)) {
                guard !showsLight else { return }
                withAnimation(.easeInOut(duration: 0.9)) { edgesClear = false }
            }
        }
        .onAppear {
            // The card now sits exactly where the page was: hide the page.
            browser.summaryCoversPage = true
            withAnimation(.spring(duration: 0.5, bounce: 0.1)) { settled = true } completion: {
                withAnimation(.easeOut(duration: 0.28)) { textShown = true }
            }
        }
    }

    private var showsLight: Bool {
        textShown && model.isWorking && !model.isClosing
    }

    // MARK: The page, becoming a card

    private func card(width: CGFloat) -> some View {
        let image = model.snapshot
        let fullHeight = image.map { width * $0.size.height / max($0.size.width, 1) } ?? cardHeight
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
            .clipShape(.rect(cornerRadius: settled ? 24 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: settled ? 24 : 0).strokeBorder(Theme.edge.opacity(settled ? 1 : 0))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(model.host)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
            }
            // Appears only once the card has reached its size, never across it.
            .opacity(textShown ? 1 : 0)
            .offset(y: textShown || model.isClosing ? 0 : 8)
        }
        .padding(.horizontal, inset)
        .padding(.top, settled ? 12 : 0)
    }

    // MARK: The summary

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.phase {
            case .failed(let message):
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryInk)
                    .transition(.opacity)
            default:
                if model.text.isEmpty {
                    StatusLine(text: model.phase == .reading ? "Reading the page" : "Writing the summary",
                               font: .system(size: 20))
                        // Out quickly, so none of it is left under the first words.
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else {
                    MarkdownText(markdown: model.text, isStreaming: model.phase == .writing)
                        // Then the summary eases up into its place, as Browse for Me's answer does.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 16))
                                .animation(.smooth(duration: 0.6).delay(0.14)),
                            removal: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .animation(.smooth(duration: 0.5), value: model.text.isEmpty)
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
        // See-through while the light is up, so its brightest part shows.
        // At the light's own pace, so no dark band crosses it as it sinks or floods.
        .background(Theme.canvas.opacity(edgesClear ? 0 : 1))
        .background(alignment: .top) { FadeEdge(color: Theme.canvas).opacity(edgesClear ? 0 : 1) }
    }

    /// The card grows back to exactly the page's size and place; only then is
    /// it swapped for the live page, in one frame, so the hand-over can't be seen.
    private func close() {
        textShown = false  // at once: only the card moves on the way out
        withAnimation(.easeOut(duration: 0.3)) { model.isClosing = true }
        withAnimation(.spring(duration: 0.45, bounce: 0)) { settled = false } completion: {
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                browser.summaryCoversPage = false
                browser.summary = nil
            }
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

/// Sits just above a footer so text scrolling under it dissolves rather than
/// being sliced off at the footer's edge. Eased over several stops so it can't band.
struct FadeEdge: View {
    let color: Color
    var height: CGFloat = 32

    var body: some View {
        LinearGradient(stops: [0, 0.1, 0.3, 0.55, 0.8, 1].map { position in
            .init(color: color.opacity(position * position * (3 - 2 * position)), location: position)
        }, startPoint: .top, endPoint: .bottom)
        .frame(height: height)
        .offset(y: -height)
        .allowsHitTesting(false)
    }
}

/// Behind the status bar of a full-screen reading view: text scrolled up
/// dissolves there instead of running into the clock and battery.
struct StatusBarFade: View {
    let color: Color
    /// The soft edge below the status bar; above it, solid.
    private let feather: CGFloat = 18

    var body: some View {
        // Sized from the real status bar height: ignoresSafeArea on a fixed
        // frame only moves it up, it doesn't make it tall enough to cover.
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            LinearGradient(stops: [.init(color: color, location: 0),
                                   .init(color: color, location: inset / (inset + feather)),
                                   .init(color: color.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: inset + feather)
                .offset(y: -inset)
        }
        .allowsHitTesting(false)
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
