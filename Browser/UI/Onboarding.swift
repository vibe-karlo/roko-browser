import SwiftUI

/// The first time roko opens: seven short pages, each with a small live
/// version of the thing it's about, playing by itself, and at most one
/// choice to make there and then. Warm light rises as roko wakes, follows
/// you from page to page, and floods the screen as you start browsing.
/// Settings → About → Show the Welcome Again brings it back.
struct Onboarding: View {
    @Environment(BrowserModel.self) private var browser
    @State private var page = 0
    @State private var forward = true
    /// Start browsing: the light floods up before the welcome lets go.
    @State private var flaring = false

    static let doneKey = "onboarding.done"

    private let count = 7

    var body: some View {
        VStack(spacing: 0) {
            top
            ZStack {
                switch page {
                case 0: Welcome()
                case 1: OneBar()
                case 2: Todos()
                case 3: Splits()
                case 4: CleanPages()
                case 5: Summaries()
                default: Private()
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                                    removal: .move(edge: forward ? .leading : .trailing))
                .combined(with: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -60 { next() } else if value.translation.width > 60 { back() }
            })

            Button(action: next) {
                Text(page == 0 ? "Get started" : page == count - 1 ? "Start browsing" : "Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(.white, in: .rect(cornerRadius: 16))
                    .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background { Atmosphere(page: page, flaring: flaring).ignoresSafeArea() }
        .opacity(flaring ? 0 : 1)
        .animation(.easeIn(duration: 0.55).delay(0.25), value: flaring)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: page)
    }

    /// Back, how far along, and Skip.
    private var top: some View {
        HStack(spacing: 0) {
            Button(action: back) {
                Glyph(.back, size: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphButtonStyle())
            .opacity(page == 0 ? 0 : 1)
            .disabled(page == 0)
            .accessibilityLabel("Back")
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index <= page ? Theme.ink : Theme.faintInk.opacity(0.4))
                        .frame(width: index == page ? 18 : 6, height: 4)
                }
            }
            .animation(.snappy(duration: 0.3), value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(count)")
            Spacer()
            Button("Skip", action: finish)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 60, height: 44)
                .contentShape(.rect)
                .opacity(page == count - 1 ? 0 : 1)
        }
        .padding(.horizontal, 8)
    }

    private func next() {
        guard page < count - 1 else { return flare() }
        forward = true
        withAnimation(.snappy(duration: 0.38)) { page += 1 }
    }

    private func back() {
        guard page > 0 else { return }
        forward = false
        withAnimation(.snappy(duration: 0.38)) { page -= 1 }
    }

    /// The last page: the light swells over everything, then roko opens.
    private func flare() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.easeOut(duration: 0.7)) { flaring = true }
        Task {
            try? await Task.sleep(for: .milliseconds(750))
            finish()
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        browser.finishOnboarding()
    }
}

// MARK: - Page layout

/// A page: its live picture in the upper part, then what it is, a line or
/// two about it, and its one choice.
private struct OnboardingPage<Demo: View, Choice: View>: View {
    let title: String
    let text: String
    @ViewBuilder let demo: () -> Demo
    @ViewBuilder let choice: () -> Choice
    /// Rises a little as the page arrives; always readable, only its place moves.
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            demo()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.system(size: 16))
                    // Over the warm light: lighter than the usual grey, to read clearly.
                    .foregroundStyle(Theme.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: risen || reduceMotion ? 0 : 10)
                    .animation(.spring(duration: 0.6, bounce: 0.2).delay(0.08), value: risen)
            }
            .offset(y: risen || reduceMotion ? 0 : 18)
            .animation(.spring(duration: 0.55, bounce: 0.2), value: risen)
            .onAppear { risen = true }
            .padding(.horizontal, 24)
            choice()
                .padding(.horizontal, 24)
                .padding(.top, 18)
            Spacer().frame(height: 22)
        }
    }
}

/// A switch set in one rounded group, as in Settings.
private struct ChoiceToggle: View {
    let title: String
    var detail: String = ""
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

private func choiceGroup(@ViewBuilder _ content: () -> some View) -> some View {
    VStack(spacing: 0) { content() }
        .background(Theme.raised, in: .rect(cornerRadius: 16))
}

// MARK: - 1. Welcome

/// roko's eclipse waking up: it grows in from small, its inner disc slides
/// across like the moon over the sun, and then keeps drifting.
private struct Welcome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var awake = false
    @State private var start = Date.now

    var body: some View {
        OnboardingPage(title: "Meet roko.",
                       text: "The browser that answers back. Quick, quiet, and on your side.") {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSince(start)
                // First the eclipse: the disc crosses in over 1.6 s, then it drifts.
                let entry = min(t / 1.6, 1)
                let eased = 1 - pow(1 - entry, 3)
                let drift = sin(max(t - 1.6, 0) * 2 * .pi / 9) * 0.12 * eased
                let shift = reduceMotion ? 0.62 : 0.05 + eased * 0.57 + drift
                Eclipse(shift: min(max(shift, 0), 1))
                    .fill(Theme.ink, style: FillStyle(eoFill: true))
                    .frame(width: 168, height: 168)
                    .scaleEffect(awake || reduceMotion ? 1 : 0.82)
            }
            .animation(.spring(duration: 1.2, bounce: 0.25), value: awake)
            .onAppear { start = .now; awake = true }
            .accessibilityHidden(true)
        } choice: {
            EmptyView()
        }
    }
}

// MARK: - 2. One bar

/// The bar typing three things by itself, and what each one gives.
private struct OneBar: View {
    @AppStorage("searchEngine") private var engine: SearchEngine = .google

    private struct Example {
        let typed: String
        let glyph: Glyph.Kind
        let answer: String
        let kind: String
    }

    private let examples = [
        Example(typed: "250 usd in eur", glyph: .equals, answer: "€223.77", kind: "Answered in the bar"),
        Example(typed: "call Petra tomorrow at 10", glyph: .todo, answer: "Call Petra", kind: "To-do · tomorrow 10:00"),
        Example(typed: "best espresso machine", glyph: .browse, answer: "Browse for Me", kind: "Reads the web and answers"),
    ]

    var body: some View {
        OnboardingPage(title: "Just type. Or say it.",
                       text: "Open a site, convert 250 dollars, add a to-do or ask anything. Hold + to speak instead.") {
            TimelineView(.periodic(from: .now, by: 0.07)) { context in
                demo(at: context.date)
            }
        } choice: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search with")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                HStack(spacing: 0) {
                    ForEach(SearchEngine.allCases, id: \.self) { option in
                        Button { withAnimation(.snappy(duration: 0.2)) { engine = option } } label: {
                            Text(option.name.replacingOccurrences(of: " Search", with: ""))
                                .font(.system(size: 14, weight: engine == option ? .semibold : .regular))
                                .foregroundStyle(engine == option ? Theme.ink : Theme.secondaryInk)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(engine == option ? Theme.panel : .clear, in: .rect(cornerRadius: 11))
                                .contentShape(.rect)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(4)
                .background(Theme.raised, in: .rect(cornerRadius: 15))
                .sensoryFeedback(.selection, trigger: engine)
            }
        }
    }

    /// Each example: typed letter by letter, its answer shown, a pause, the next.
    private func demo(at date: Date) -> some View {
        let cycle = 4.2
        let t = date.timeIntervalSinceReferenceDate
        let index = Int(t / cycle) % examples.count
        let into = t.truncatingRemainder(dividingBy: cycle)
        let example = examples[index]
        let letters = min(example.typed.count, Int(into / 0.06))
        let typed = String(example.typed.prefix(letters))
        let answered = letters == example.typed.count && into > Double(example.typed.count) * 0.06 + 0.25

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Glyph(.search, size: 17).foregroundStyle(Theme.secondaryInk)
                (Text(typed) + Text(answered ? "" : "|").foregroundStyle(Theme.accentText))
                    .font(.system(size: 17))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Theme.raised, in: .rect(cornerRadius: 18))

            HStack(spacing: 12) {
                Glyph(example.glyph, size: 20).foregroundStyle(Theme.secondaryInk).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(example.answer).font(.system(size: 20, weight: .semibold))
                    Text(example.kind).font(.system(size: 13)).foregroundStyle(Theme.secondaryInk)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 70)
            .background(Theme.panel, in: .rect(cornerRadius: 18))
            .opacity(answered ? 1 : 0.35)
            .animation(.easeOut(duration: 0.2), value: answered)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 3. Clean pages

/// A page with a cookie pop-up and two ads, cleaned before your eyes.
private struct CleanPages: View {
    @State private var ads = ContentBlocker.shared.isEnabled(.ads)
    @State private var cookies = ContentBlocker.shared.isEnabled(.cookies)

    var body: some View {
        OnboardingPage(title: "No ads. No pop-ups.",
                       text: "Ads and trackers never load, and cookie banners get a polite no before you ever see them.") {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                MiniPage(clean: (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.4)) > 1.6,
                         blocking: ads || cookies)
            }
        } choice: {
            choiceGroup {
                ChoiceToggle(title: "Block ads and trackers", isOn: Binding(get: { ads }, set: { on in
                    ads = on
                    ContentBlocker.shared.setEnabled(.ads, on)
                    ContentBlocker.shared.setEnabled(.privacy, on)
                }))
                ChoiceToggle(title: "Reject cookie pop-ups", isOn: Binding(get: { cookies }, set: { on in
                    cookies = on
                    ContentBlocker.shared.setEnabled(.cookies, on)
                }))
            }
        }
    }
}

/// A tiny recipe page: an ad, the text, a cookie pop-up over it. Cleaned, the
/// ads fold away where they are and the pop-up slides off; nothing jumps.
private struct MiniPage: View {
    let clean: Bool
    let blocking: Bool

    private var tidy: Bool { clean && blocking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Theme.secondaryInk).frame(width: 9, height: 9)
                Text("eatathens.com").font(.system(size: 11)).foregroundStyle(Theme.secondaryInk)
                Spacer()
                Text("14 blocked")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                    .opacity(tidy ? 1 : 0)
            }
            .padding(.bottom, 10)
            ad
            Text("Lemon pasta").font(.system(size: 18, weight: .bold)).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<4, id: \.self) { line in
                    Capsule().fill(Theme.faintInk.opacity(0.45))
                        .frame(maxWidth: line == 3 ? 120 : .infinity)
                        .frame(height: 6)
                }
            }
            .padding(.bottom, 10)
            ad
        }
        .padding(16)
        .frame(width: 290)
        .background(Theme.panel, in: .rect(cornerRadius: 22))
        .overlay(alignment: .bottom) { popup }
        .clipShape(.rect(cornerRadius: 22))
        .animation(.snappy(duration: 0.5), value: tidy)
        .accessibilityHidden(true)
    }

    /// Folds to nothing in place when cleaned.
    private var ad: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.raised)
            .overlay(Text("AD").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faintInk))
            .frame(height: tidy ? 0 : 38)
            .opacity(tidy ? 0 : 1)
            .padding(.bottom, tidy ? 0 : 10)
    }

    private var popup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("We value your privacy").font(.system(size: 12, weight: .semibold))
            Text("We and our 812 partners use cookies to…").font(.system(size: 10)).foregroundStyle(Theme.secondaryInk)
            HStack {
                Text("Accept all").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Theme.ink.opacity(0.85), in: .rect(cornerRadius: 6))
                    .foregroundStyle(Theme.canvas)
                Text("Manage").font(.system(size: 10)).foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: .rect(cornerRadius: 14))
        .padding(10)
        .offset(y: tidy ? 160 : 0)
    }
}

// MARK: - 4. Summaries

/// A page pulled down past the reload point turning into its summary.
private struct Summaries: View {
    @AppStorage(Preferences.pullToSummarizeKey) private var pull = true

    var body: some View {
        OnboardingPage(title: "Pull for the gist.",
                       text: "Pull down to reload. Keep pulling and the page turns into its summary: the ingredients, the steps, the picks.") {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                PullDemo(phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5)
            }
        } choice: {
            choiceGroup {
                ChoiceToggle(title: "Pull further to summarize", isOn: $pull)
            }
        }
    }
}

/// 0...0.35 the page is pulled down, 0.35...0.5 it shrinks into a card,
/// 0.5...0.9 the summary reads, then back.
private struct PullDemo: View {
    let phase: Double

    var body: some View {
        let pull = min(phase / 0.35, 1)
        let summarized = phase > 0.42 && phase < 0.92
        ZStack(alignment: .top) {
            // The ring that fills as the pull goes on, then says Summarize.
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Theme.faintInk.opacity(0.4), lineWidth: 2.5)
                    Circle().trim(from: 0, to: pull).stroke(Theme.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                if pull >= 1 { Text("Summarize").font(.system(size: 13, weight: .semibold)) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Theme.raised, in: .capsule)
            .opacity(summarized ? 0 : (phase < 0.38 ? 1 : 0))

            Group {
                if summarized { summary } else { page }
            }
            .offset(y: summarized ? 0 : 48 * pull)
        }
        .frame(maxWidth: 300)
        .animation(.snappy(duration: 0.4), value: summarized)
        .accessibilityHidden(true)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lemon pasta").font(.system(size: 18, weight: .bold))
            ForEach(0..<6, id: \.self) { line in
                Capsule().fill(Theme.faintInk.opacity(0.45))
                    .frame(maxWidth: line % 3 == 2 ? 140 : .infinity).frame(height: 6)
            }
        }
        .padding(16)
        .background(Theme.panel, in: .rect(cornerRadius: 22))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.panel).frame(width: 30, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lemon pasta").font(.system(size: 15, weight: .semibold))
                    Text("20 min · serves 2").font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
                }
            }
            ForEach(["Spaghetti, 200 g", "1 lemon, zest and juice", "Parmesan, a handful"], id: \.self) { item in
                HStack(spacing: 8) {
                    Circle().stroke(Theme.faintInk, lineWidth: 1.5).frame(width: 13, height: 13)
                    Text(item).font(.system(size: 13))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: .rect(cornerRadius: 22))
        .transition(.scale(scale: 1.1).combined(with: .opacity))
    }
}

// MARK: - To-do

/// Typing a to-do the way you'd say it, and it becoming one: on its day, at
/// its time, then ticked off.
private struct Todos: View {
    @AppStorage(Preferences.bandTodayKey) private var today = true

    var body: some View {
        OnboardingPage(title: "Say it, and it's a to-do.",
                       text: "Type \u{201C}call Petra tomorrow at 10\u{201D} in the bar. roko knows the day and the time, reminds you, and keeps today's list under the page.") {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                TodoDemo(t: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6.5))
            }
        } choice: {
            choiceGroup {
                ChoiceToggle(title: "Today's to-dos under the page", detail: "A thin strip with what's left for today", isOn: $today)
            }
        }
    }
}

/// 0...1.6 typed, 1.6...2.2 it lifts into the list, 3.4 ticked, 5 struck out.
private struct TodoDemo: View {
    let t: Double
    private let typed = "call Petra tomorrow at 10"

    var body: some View {
        let letters = min(typed.count, Int(t / 0.055))
        let landed = t > 1.75
        let ticked = t > 3.6
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Glyph(.plus, size: 16).foregroundStyle(Theme.secondaryInk)
                Text(String(typed.prefix(letters)))
                    .font(.system(size: 16))
                    .lineLimit(1)
                    .opacity(landed ? 0 : 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Theme.raised, in: .rect(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 0) {
                Text("Tomorrow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.bottom, 8)
                row(title: "Pick up the dry cleaning", time: nil, done: false)
                // Unfolds in place under the first: nothing slides over anything.
                row(title: "Call Petra", time: "10:00", done: ticked)
                    .frame(height: landed ? 50 : 0, alignment: .top)
                    .opacity(landed ? 1 : 0)
                    .clipped()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: .rect(cornerRadius: 20))
        }
        .frame(maxWidth: 320)
        .animation(.spring(duration: 0.5, bounce: 0.25), value: landed)
        .animation(.snappy(duration: 0.3), value: ticked)
        .sensoryFeedback(.success, trigger: ticked) { _, now in now }
        .accessibilityHidden(true)
    }

    private func row(title: String, time: String?, done: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(done ? Atmosphere.orange : Theme.faintInk, lineWidth: 1.6)
                if done {
                    Circle().fill(Atmosphere.orange).padding(4)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15))
                    .strikethrough(done, color: Theme.secondaryInk)
                    .foregroundStyle(done ? Theme.secondaryInk : Theme.ink)
                if let time { Text(time).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryInk) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Split View

/// Two pages at once, the band between them gliding up and down.
private struct Splits: View {
    var body: some View {
        OnboardingPage(title: "Two pages at once.",
                       text: "A recipe above, the shopping list below. Drag the line between them anywhere, or turn your iPhone to see them side by side.") {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                SplitDemo(t: context.date.timeIntervalSinceReferenceDate)
            }
        } choice: {
            EmptyView()
        }
    }
}

private struct SplitDemo: View {
    let t: Double

    var body: some View {
        let fraction = 0.5 + sin(t * 2 * .pi / 5) * 0.16
        GeometryReader { proxy in
            let total = proxy.size.height
            let band: CGFloat = 18
            let top = (total - band) * fraction
            VStack(spacing: 0) {
                card(title: "Lemon pasta", lines: 6)
                    .frame(height: top)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 16,
                                                      bottomTrailingRadius: 16, topTrailingRadius: 22))
                Capsule().fill(.white.opacity(0.45)).frame(width: 34, height: 4)
                    .frame(height: band)
                shopping
                    .frame(maxHeight: .infinity)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 22,
                                                      bottomTrailingRadius: 22, topTrailingRadius: 16))
            }
        }
        .padding(8)
        .background(Color.black, in: .rect(cornerRadius: 30))
        .frame(width: 230, height: 300)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private func card(title: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
            ForEach(0..<lines, id: \.self) { line in
                Capsule().fill(Color.black.opacity(0.13))
                    .frame(maxWidth: line % 3 == 2 ? 90 : .infinity).frame(height: 5)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private var shopping: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Shopping").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
            ForEach(["Spaghetti", "Lemons", "Parmesan"], id: \.self) { item in
                HStack(spacing: 8) {
                    Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1.4).frame(width: 13, height: 13)
                    Text(item).font(.system(size: 13)).foregroundStyle(.black.opacity(0.8))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.96))
    }
}

// MARK: - 6. Private

/// No account, nothing kept, and private tabs behind Face ID if you like.
private struct Private: View {
    @State private var locked = PrivacyLock.shared.isEnabled
    @State private var spin = false

    var body: some View {
        OnboardingPage(title: "Yours alone.",
                       text: "No account and nothing sent about you. Private tabs vanish the moment you close them.") {
            VStack(spacing: 18) {
                Glyph(locked ? .lock : .eyeClosed, size: 64)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Theme.ink)
                    .animation(.snappy(duration: 0.3), value: locked)
                HStack(spacing: 18) {
                    ForEach(["No account", "No tracking", "Nothing sold"], id: \.self) { item in
                        Text(item).font(.system(size: 13)).foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
            .accessibilityHidden(true)
        } choice: {
            if PrivacyLock.isAvailable {
                choiceGroup {
                    ChoiceToggle(title: "Lock private tabs", detail: "With \(PrivacyLock.method), from each time roko opens",
                                 isOn: Binding(get: { locked }, set: { on in
                        if on {
                            Task { locked = await PrivacyLock.shared.turnOn() }
                        } else {
                            PrivacyLock.shared.isEnabled = false
                            locked = false
                        }
                    }))
                }
            }
        }
    }
}

// MARK: - Atmosphere

/// Behind every page: roko's orange as warm light rising from the bottom
/// edge, drifting slowly, and moving across as you go from page to page.
/// Brightest on the first page, quieter while you read the rest.
private struct Atmosphere: View {
    let page: Int
    var flaring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// roko waking: the light rises from nothing in the first moments.
    @State private var risen = false

    static let orange = Color(red: 1, green: 0x5B / 255, blue: 0x1F / 255)
    static let amber = Color(red: 1, green: 0xA8 / 255, blue: 0x4A / 255)
    static let ember = Color(red: 0xB8 / 255, green: 0x2E / 255, blue: 0x0C / 255)

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let drift = sin(t * 2 * .pi / 14) * 0.08
                let across = [0.5, 0.25, 0.75, 0.3, 0.7, 0.4, 0.5][min(page, 6)]
                let x = flaring ? 0.5 : across + drift
                let strength = flaring ? 1.0 : (risen ? (page == 0 ? 0.75 : 0.45) : 0.0)
                let reach = flaring ? 1.6 : (risen ? 0.62 : 0.3)
                ZStack {
                    Theme.canvas
                    RadialGradient(colors: [Self.amber.opacity(strength), Self.orange.opacity(strength * 0.8),
                                            Self.ember.opacity(strength * 0.35), .clear],
                                   center: UnitPoint(x: x, y: flaring ? 0.75 : 1.12), startRadius: 0,
                                   endRadius: proxy.size.height * reach)
                    RadialGradient(colors: [Self.orange.opacity(strength * 0.35), .clear],
                                   center: UnitPoint(x: 1 - x * 0.6, y: 1.05), startRadius: 0,
                                   endRadius: proxy.size.height * 0.4)
                }
                .animation(.easeInOut(duration: 0.9), value: page)
                .animation(.easeOut(duration: 1.8), value: risen)
                .animation(.easeOut(duration: 0.7), value: flaring)
            }
            .onAppear { risen = true }
            .overlay { LightGrain().opacity(0.06).blendMode(.overlay) }
        }
        .allowsHitTesting(false)
    }
}

/// A fine still noise over the light, so the gradient never bands.
private struct LightGrain: View {
    var body: some View {
        Canvas { context, size in
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<Int(size.width * size.height / 14) {
                let x = Double.random(in: 0..<size.width, using: &generator)
                let y = Double.random(in: 0..<size.height, using: &generator)
                let shade = Double.random(in: 0...1, using: &generator)
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                             with: .color(Color(white: shade)))
            }
        }
        .drawingGroup()
    }
}

