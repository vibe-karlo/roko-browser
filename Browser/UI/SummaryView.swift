import SwiftUI

/// Full-screen summary. It opens on the page itself, which shrinks into a card
/// at the top (from a pull, it picks up where the finger left the card); a light passes down the card
/// while it's read, then the summary writes itself below. Closing plays it
/// backwards: the card grows into the page again.
struct SummaryView: View {
    @Environment(BrowserModel.self) private var browser
    let model: SummaryModel

    /// 0: the card fills the screen as the page did. 1: it's the card.
    @State private var settle: CGFloat
    /// Where a pull had the card, easing up to its place.
    @State private var lift: CGFloat
    /// 0 to 1 over the card's flight: it tips back on its way into place and
    /// comes upright as it lands. 0 and 1 are flat, so a pull hands over untilted.
    @State private var flight: CGFloat = 0
    /// The title and summary show only once the card has come to rest.
    @State private var textShown = false
    /// No canvas under the footer or the status bar while the light is up and
    /// on through its flood. Set here, so it never flickers solid for the frame
    /// between the light going and the flood starting.
    @State private var edgesClear = false
    /// How far down the summary the reader is, for the line above the bar.
    @State private var readProgress = 0.0
    private let fullCardHeight: CGFloat = 210
    /// Once the summary is there, the card makes room for it: the page is a
    /// reminder by then, not something to read.
    private var cardHeight: CGFloat { model.text.isEmpty || model.isClosing ? fullCardHeight : 72 }

    init(model: SummaryModel) {
        self.model = model
        _settle = State(initialValue: model.handoff?.settle ?? 0)
        _lift = State(initialValue: model.handoff?.offset ?? 0)
    }

    private var settled: Bool { settle >= 1 }
    /// On screen: the light comes with the card, not after it.
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // From a pull the dark is already all there.
                Theme.canvas
                    .opacity(model.handoff != nil && !model.isClosing ? 1 : settle)
                    .ignoresSafeArea()

                // roko's light while it works: there as the card flies in, rising as
                // the page is read, flooding the screen as the summary starts.
                if appeared {
                    WorkingGlow(progress: model.progress, isActive: showsLight,
                                finished: !model.isWorking && !model.isClosing && !model.phase.isFailure)
                        .ignoresSafeArea()
                }

                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            card(width: proxy.size.width)
                                .animation(.smooth(duration: 0.6), value: model.text.isEmpty)
                                .modifier(CardFlight(flight: flight))
                                .offset(y: lift)
                                .id("card")
                            content(scroller)
                                .opacity(textShown ? 1 : 0)
                                .offset(y: textShown || model.isClosing ? 0 : 12)
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollDisabled(!settled)
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: Double.self) { ReadingLine.progress($0) } action: { _, progress in
                        readProgress = progress
                    }
                    .onChange(of: model.isClosing) { _, closing in
                        // Closing from further down: the card returns to the top as it grows.
                        if closing { scroller.scrollTo("card", anchor: .top) }
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
            HitchWatch.note("summary appeared")
            // The card now sits exactly where the page was: hide the page.
            browser.summaryCoversPage = true
            appeared = true
            // The rest of the way (from a pull, from where the finger let go),
            // tipping back and coming upright as it goes.
            withAnimation(.easeInOut(duration: 0.8)) { flight = 1 }
            withAnimation(.smooth(duration: 0.8)) {
                settle = 1
                lift = 0
            } completion: {
                withAnimation(.easeOut(duration: 0.28)) { textShown = true }
            }
        }
    }

    private var showsLight: Bool {
        appeared && model.isWorking && !model.isClosing
    }

    // MARK: The page, becoming a card

    private func card(width: CGFloat) -> some View {
        let image = model.snapshot
        let fullHeight = image.map { width * $0.size.height / max($0.size.width, 1) } ?? cardHeight
        let inset: CGFloat = 22 * settle
        return VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width - inset * 2, height: fullHeight + (cardHeight - fullHeight) * settle, alignment: .top)
                        .clipped()
                } else {
                    Theme.raised.frame(height: cardHeight)
                }
                if settled, model.phase == .reading || (model.phase == .writing && model.text.isEmpty) {
                    ScanLight()
                }
            }
            .clipShape(.rect(cornerRadius: 24 * settle, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24 * settle, style: .continuous).strokeBorder(Theme.edge.opacity(settle))
            }

            // Once the summary is there, the page is a reference: one quiet
            // line, so the summary below is what the eye lands on.
            let compact = !model.text.isEmpty && !model.isClosing
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: compact ? 14 : 15, weight: compact ? .medium : .semibold))
                    .foregroundStyle(compact ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(compact ? 1 : 2)
                Text(model.host)
                    .font(.system(size: 13))
                    .foregroundStyle(compact ? Theme.faintInk : Theme.secondaryInk)
            }
            // Appears only once the card has reached its size, never across it.
            .opacity(textShown ? 1 : 0)
            .offset(y: textShown || model.isClosing ? 0 : 8)
        }
        .padding(.horizontal, inset)
        .padding(.top, 12 * settle)
    }

    // MARK: The summary

    @ViewBuilder
    private func content(_ scroller: ScrollViewProxy) -> some View {
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
                    VStack(alignment: .leading, spacing: 24) {
                        // No section chips: a summary is short enough to scroll,
                        // and they competed with the gist for the top.
                        MarkdownText(markdown: model.text, isStreaming: model.phase == .writing, anchor: "summary")
                        // Signed at the end, so a screenshot says where it came from,
                        // and it never floats over the text above the bar.
                        if model.phase == .done {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                RokoSignature()
                                Text([Self.credit(model.engine), model.readingTime, model.note].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.faintInk)
                                    .lineLimit(2)
                            }
                            .transition(.opacity)
                        }
                    }
                    // Then the summary comes into focus: blurred at first, sharpening as it settles.
                    .transition(.asymmetric(
                        insertion: AnyTransition(.blurReplace(.downUp)).combined(with: .offset(y: 10))
                            .animation(.smooth(duration: 0.75).delay(0.1)),
                        removal: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .animation(.smooth(duration: 0.5), value: model.text.isEmpty)
    }

    /// The app's bar: back to the page, and a question about it from the middle.
    private var footer: some View {
        ContextBar(leading: .init(glyph: .close, label: "Back to the page", action: close),
                   glyph: .browse, title: "Ask",
                   launch: { browser.showCommandBar(context: .aboutPage) }, fades: false)
            .padding(.top, 10)
            .overlay(alignment: .top) { ReadingLine(progress: readProgress, tint: PageKind.of(model.text).tint) }
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
        withAnimation(.spring(duration: 0.45, bounce: 0)) { settle = 0 } completion: {
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
        case "Claude": "Written by Claude"
        case "Apple Intelligence": "Written by Apple Intelligence, privately in Apple's cloud"
        default: "Written on this iPhone"
        }
    }
}

/// The card tipped back mid-flight, top away, as a card laid down and picked
/// up again: flat at the start and the end, most tipped halfway. Animatable,
/// so SwiftUI works the angle out for every frame rather than easing between
/// the two ends, which are both flat.
private struct CardFlight: ViewModifier, Animatable {
    var flight: CGFloat

    var animatableData: CGFloat {
        get { flight }
        set { flight = newValue }
    }

    func body(content: Content) -> some View {
        let lift = sin(CGFloat.pi * flight)
        content
            .rotation3DEffect(.degrees(56 * lift), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.7)
            .scaleEffect(1 - 0.12 * lift)
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
