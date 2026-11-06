import SwiftUI

/// The first time roko opens: why it's here, in numbers, then the browser itself.
/// The eclipse closes in roko's light and steps aside for one list of ten browsers,
/// racing in true time, from the test that's on the website; Continue sorts the same
/// list again for what each one left on the page. Then the light carries off the top
/// with the real launcher and its keyboard under it, and FirstMinuteGuide takes over.
/// Settings → About → Show the Welcome Again brings it back.
struct Onboarding: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Namespace private var markSpace

    private enum Stage: Int { case wake, speed, clean }

    /// Closing as it appears: from a little past the icon's place, into it.
    @State private var eclipse = 0.12
    @State private var stage = Stage.wake
    @State private var flaring = false
    /// The race has started: every bar runs for as long as that browser took.
    @State private var racing = false
    /// True, or not there: reopening the welcome from Settings isn't a launch.
    @State private var opened: String?
    @State private var running: Task<Void, Never>?

    static let doneKey = "onboarding.done"
    /// For the first minute's receipt: true, or not on it.
    fileprivate static var openedIn: String?

    /// docs/real-site-test-2026-11-05.md, as on the website's scoreboard (Site/site.js).
    private struct Run: Identifiable {
        let name: String
        let seconds: Double
        let cleanSites: Int
        var id: String { name }
    }

    private static let runs = [
        Run(name: "roko", seconds: 1.07, cleanSites: 6), Run(name: "Quiche", seconds: 1.70, cleanSites: 2),
        Run(name: "Lens", seconds: 2.76, cleanSites: 3), Run(name: "Arc Search", seconds: 3.41, cleanSites: 2),
        Run(name: "Firefox", seconds: 3.47, cleanSites: 1), Run(name: "Brave", seconds: 3.54, cleanSites: 3),
        Run(name: "DuckDuckGo", seconds: 4.33, cleanSites: 3), Run(name: "Chrome", seconds: 4.96, cleanSites: 0),
        Run(name: "Safari", seconds: 4.96, cleanSites: 0), Run(name: "Edge", seconds: 5.46, cleanSites: 0),
    ]
    private static let slowest = 5.46

    /// Sideways there's room for the leaders alone. The headline still says how many.
    private var shown: Int { verticalSizeClass == .compact ? 4 : Self.runs.count }
    private var rowHeight: CGFloat { verticalSizeClass == .compact ? 32 : 40 }

    private var order: [Run] {
        let sorted = stage == .clean
            ? Self.runs.enumerated().sorted { ($0.element.cleanSites, -$0.offset) > ($1.element.cleanSites, -$1.offset) }.map(\.element)
            : Self.runs
        return sorted
    }

    var body: some View {
        ZStack {
            if stage == .wake {
                Eclipse(shift: reduceMotion ? 0.62 : eclipse)
                    .fill(Theme.ink, style: FillStyle(eoFill: true))
                    .matchedGeometryEffect(id: "mark", in: markSpace)
                    .frame(width: 104, height: 104)
                    .accessibilityLabel("roko")
            } else {
                content
                    .transition(.opacity)
            }
        }
        .opacity(flaring ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: flaring)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.canvas
                    .opacity(flaring ? 0 : 1)
                    .animation(.easeIn(duration: 0.55).delay(0.25), value: flaring)
                WorkingGlow(progress: stage == .clean ? 0.45 : 0.25, isActive: !flaring, finished: flaring,
                            across: stage == .clean ? 0.6 : 0.4, drifts: true, riseDuration: 0.9)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: stage)
        .task { await wake() }
        .onDisappear { running?.cancel() }
    }

    private func wake() async {
        let elapsed = LaunchClock.elapsed
        if elapsed < 500 {
            opened = String(format: "You just opened it in %.2f s.", elapsed / 1000)
            Self.openedIn = String(format: "%.2f s", elapsed / 1000)
        }
        withAnimation(.spring(duration: 0.8, bounce: 0.1)) { eclipse = 0.62 }
        try? await Task.sleep(for: .seconds(0.85))
        withAnimation(.spring(duration: 0.5, bounce: 0.08)) { stage = .speed }
        try? await Task.sleep(for: .seconds(0.35))
        racing = true
        guard !reduceMotion else { return }
        // A tick as roko crosses the line, in true time like everything else here.
        running = Task {
            try? await Task.sleep(for: .seconds(Self.runs[0].seconds))
            if !Task.isCancelled, stage == .speed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
    }

    // MARK: The case

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Eclipse(shift: reduceMotion ? 0.62 : eclipse)
                    .fill(Theme.ink, style: FillStyle(eoFill: true))
                    .matchedGeometryEffect(id: "mark", in: markSpace)
                    .frame(width: 22, height: 22)
                Text("roko").font(.system(size: 20, weight: .bold))
                Spacer(minLength: 0)
                Button("Skip", action: flare)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.bodyInk)
                    .frame(width: 60, height: 44)
                    .contentShape(.rect)
                    .padding(.trailing, -14)
            }
            .frame(height: 44)

            Group {
                Text(stage == .clean ? "The fewest ads and pop-ups." : "The fastest of ten browsers.")
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(stage == .clean ? "Ad-heavy sites with no ad, pop-up or wall." : opened ?? "Tap a link. Half the page is there in about a second.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.bodyInk)
                    .padding(.top, 8)
            }
            .id(stage)
            .transition(.opacity.animation(.easeIn(duration: 0.2).delay(0.1)))
            .padding(.top, 10)

            Spacer(minLength: 12)
            board
            Spacer(minLength: 12)

            Text(stage == .clean
                 ? "Six ad-heavy sites, five swipes down each, one run each, judged by eye. iPhone 17 Pro, iOS 27.2, November 2026."
                 : "Time until half the page is drawn. Median of 24 runs each on eight sites, on iPhone 17 Pro, iOS 27.2, November 2026. Yours will vary.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .id(stage)
                .transition(.opacity.animation(.easeIn(duration: 0.2).delay(0.1)))
                .padding(.bottom, 12)

            Button(action: next) {
                Text(stage == .clean ? "Start browsing" : "Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.ink, in: .rect(cornerRadius: 16))
                    .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
    }

    /// One list, sorted again for each thing it measures: each browser keeps its row
    /// and moves to its new place.
    private var board: some View {
        let places = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.id, $0.offset) })
        return ZStack(alignment: .top) {
            ForEach(Self.runs) { run in
                let place = places[run.id] ?? 0
                row(run)
                    .frame(height: rowHeight, alignment: .top)
                    .offset(y: CGFloat(place) * rowHeight)
                    .opacity(place < shown ? 1 : 0)
                    .animation(.spring(duration: 0.55, bounce: 0.08).delay(Double(place) * 0.015), value: stage)
            }
        }
        .frame(height: CGFloat(shown) * rowHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage == .clean
                            ? "With no ad, pop-up or wall: roko on 6 of 6 sites, Brave, DuckDuckGo and Lens on 3, Safari, Chrome and Edge on none."
                            : "Half the page drawn: roko in 1.07 seconds, Chrome and Safari in 4.96, Edge in 5.46.")
    }

    private func row(_ run: Run) -> some View {
        let isRoko = run.name == "roko"
        let share = stage == .clean ? Double(run.cleanSites) / 6 : run.seconds / Self.slowest
        return VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.name)
                    .font(.system(size: 14, weight: isRoko ? .bold : .regular))
                    .foregroundStyle(isRoko ? Theme.ink : Theme.bodyInk)
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    // Its time comes up as its bar arrives, not before.
                    Text(String(format: "%.2f s", run.seconds))
                        .opacity(stage == .speed && racing ? 1 : 0)
                        .animation(stage == .speed && !reduceMotion ? .easeOut(duration: 0.15).delay(run.seconds) : .easeOut(duration: 0.15), value: racing)
                    Text("\(run.cleanSites) of 6")
                        .opacity(stage == .clean ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: stage)
                }
                .font(.system(size: 14, weight: isRoko ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isRoko ? Theme.ink : Theme.bodyInk)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(isRoko ? Theme.accent : Color.white.opacity(0.42))
                            // A sliver for none at all: the row's still in the running.
                            .frame(width: max(racing ? proxy.size.width * share : 0, racing ? 6 : 0))
                            .animation(stage == .speed && !reduceMotion ? .linear(duration: run.seconds) : .spring(duration: 0.55, bounce: 0.06), value: racing)
                            .animation(.spring(duration: 0.55, bounce: 0.06), value: stage)
                    }
            }
            .frame(height: 6)
        }
    }

    private func next() {
        if stage == .speed {
            racing = true
            withAnimation(.spring(duration: 0.5, bounce: 0.08)) { stage = .clean }
        } else {
            flare()
        }
    }

    /// The light carries off the top, with the real launcher and its keyboard under
    /// it, in time for the cover's own fade (BrowserView, 0.35 s) to end as the light does.
    private func flare() {
        guard !flaring else { return }
        running?.cancel()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        flaring = true
        Task {
            try? await Task.sleep(for: .seconds(WorkingGlow.sweepDuration - 0.35))
            UserDefaults.standard.set(true, forKey: Self.doneKey)
            browser.guiding = true
            browser.finishOnboarding()
        }
    }
}

/// A few words over the real browser, for its first minute, and only while they're
/// true: what to try in the launcher, what just happened to the page, what to do to
/// it next. Everything that happens is the app doing it: a try is typed into the
/// real field, Go is the real key, the page itself shows the pull, the summary is of
/// the real page. Whatever you do instead just moves it along. It ends in a receipt
/// of what really happened and the rest of what's in here, each opening the real
/// screen, and then it's gone. It costs nothing: it's only here for this minute, and
/// it redraws only when one of the few things it reads changes.
struct FirstMinuteGuide: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Step: Equatable {
        case ask, opened, story, pull, receipt, more
    }

    @State private var step = Step.ask
    @State private var typing: Task<Void, Never>?
    @State private var showing: Task<Void, Never>?
    /// The try that's been typed: Go is next, if Go does something with it.
    @State private var tried: String?
    /// What's true about the page just opened.
    @State private var fact = ""
    /// How the page's arrival went, for the receipt.
    @State private var pageTook: String?
    /// The summary read, for its "3 min read → 20 s".
    @State private var summary: SummaryModel?
    /// What had been counted before this minute: the receipt is for this minute alone.
    @State private var before = SavedStats.totals
    /// The light carrying off the top as the page arrives in its wake.
    @State private var sweep = Sweep.none
    /// The page dipping by itself, with what a real pull shows above it.
    @State private var dipping = false

    private enum Sweep { case none, up, leaving }

    /// Opened from the rest of what's in here.
    @State private var visited: Set<String> = []
    private static let more: [(title: String, detail: String, glyph: Glyph.Kind, panel: BrowserModel.Panel)] = [
        ("To-do", "Type a task in the bar, with its time.", .todo, .todos),
        ("Saved", "Keep a page to read later, even offline.", .readLater, .readLater),
        ("News", "The sites you choose, each story once.", .news, .feed),
        ("Today", "Weather, your calendar and to-dos each morning.", .today, .today),
    ]

    private static let canAsk = ClaudeClient.configured != nil || AppleModels.cloudIfAvailable != nil || OnDeviceSummarizer.isAvailable

    /// Sites we've measured roko on, with plenty on them for it to take away.
    private static let site: String = switch Locale.current.region?.identifier {
    case "HR": "index.hr"
    case "US": "cnn.com"
    default: "theguardian.com"
    }
    private static let question = "best espresso machine?"
    private var tries: [(String, Glyph.Kind)] {
        [("250 usd in eur", .equals),
         Self.canAsk ? (Self.question, .browse) : ("call mum tomorrow at 10", .todo),
         (Self.site, .globe)]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if sweep != .none {
                WorkingGlow(progress: 0.35, isActive: sweep == .up, finished: sweep == .leaving, riseDuration: 0.12)
                    .environment(\.colorScheme, .dark)
                    .ignoresSafeArea()
            }
            if dipping {
                HStack(spacing: 6) {
                    Glyph(.summarize, size: 15)
                    Text("Summarize").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Theme.raised, in: .capsule)
                .environment(\.colorScheme, .dark)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            if step == .ask, browser.panel == .command, !browser.guideStepsAside {
                launcherHint.transition(.offset(y: 12).combined(with: .opacity))
            } else if step == .receipt, browser.panel == .none {
                FirstMinuteReceipt(lines: receiptLines, saved: savedLine, still: reduceMotion) { step = .more }
                    .transition(.opacity)
            } else if step == .more, browser.panel == .none, browser.summary == nil, browser.browseForMe == nil {
                moreHint.transition(.offset(y: 12).combined(with: .opacity))
            } else if browser.panel == .none, browser.summary == nil, browser.browseForMe == nil, let words {
                pageHint(words)
                    .id(words)
                    .transition(.offset(y: 12).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.1), value: step)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: fact)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: browser.panel)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: browser.guideStepsAside)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: browser.panel) { was, now in
            if was == .command, now == .none, browser.selectedTab?.url != nil, step == .ask { pageOpened(at: CACurrentMediaTime()) }
        }
        .onChange(of: browser.selectedTab?.url) {
            if step == .story, onStory { pull() }
            // Off browsing: what's left of the list can wait for the tabs.
            if step == .more { browser.guiding = false }
        }
        .onChange(of: browser.summary == nil) { _, closed in
            if !closed {
                summary = browser.summary
                showing?.cancel()
            } else if step == .pull || step == .story {
                step = .receipt
            }
        }
        .onChange(of: browser.browseForMe == nil) { _, closed in
            if closed, step == .ask { step = .receipt }
        }
        .onDisappear {
            typing?.cancel()
            showing?.cancel()
        }
    }

    // MARK: In the launcher

    /// Above the keyboard, clear of the answers under the field.
    private var launcherHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                GuideMark()
                Text(tried == Self.site || tried == Self.question ? "Now tap Go."
                    : verticalSizeClass == .compact ? "Type anything." : "Type anything, or try one.")
                    .font(.system(size: 15, weight: .medium))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.leading, 14)
            // Sideways, the keyboard leaves room for the words alone.
            ForEach(verticalSizeClass == .compact ? [] : tries, id: \.0) { text, glyph in
                Button { type(text) } label: {
                    HStack(spacing: 12) {
                        Glyph(glyph, size: 18).foregroundStyle(Theme.secondaryInk)
                        Text(text).font(.system(size: 16)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(tried == text ? Theme.selection : .clear, in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(6)
        .barSurface(cornerRadius: 20)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 480)
    }

    /// Letter by letter into the real field, so the real answer comes up with it.
    private func type(_ text: String) {
        typing?.cancel()
        tried = text
        browser.commandPrefill = ""
        typing = Task {
            if reduceMotion {
                browser.commandPrefill = text
                return
            }
            var typed = ""
            for letter in text {
                typed.append(letter)
                browser.commandPrefill = typed
                try? await Task.sleep(for: .milliseconds(38))
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: On the page

    private var words: String? {
        switch step {
        case .ask, .receipt, .more: nil
        case .opened: fact.isEmpty ? nil : fact
        case .story: "Open a story."
        case .pull: "Pull it down, past reload, until it says Summarize. Then let go."
        }
    }

    /// A page of its own, not a site's front page or a section of it, whose summary
    /// would be stray headlines.
    private var onStory: Bool {
        (browser.selectedTab?.url?.pathComponents.count ?? 0) > 2
    }

    /// Where a toast goes, above the bar. The finger goes straight through it to the page.
    private func pageHint(_ words: String) -> some View {
        HStack(spacing: 10) {
            GuideMark()
                .allowsHitTesting(false)
            Text(words)
                .font(.system(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            // Its tap target reaches past the card without making the card taller.
            closeButton.padding(.vertical, -12).padding(.trailing, -8)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 18).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.edge))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 480)
        .padding(.bottom, Theme.barHeight + 24)
        .onAppear { AccessibilityNotification.Announcement(words).post() }
    }

    private var closeButton: some View {
        Button { browser.guiding = false } label: {
            Glyph(.close, size: 14, weight: 2)
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel("Stop the tips")
    }

    // MARK: The rest of it

    /// Each one opens the real screen, and is ticked when you come back.
    private var moreHint: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                GuideMark()
                Text(visited.count == Self.more.count ? "That's the lot. Enjoy." : "There's more in here.")
                    .font(.system(size: 15, weight: .medium))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                closeButton
            }
            .padding(.leading, 14)
            ForEach(Self.more, id: \.title) { item in
                Button {
                    visited.insert(item.title)
                    browser.panel = item.panel
                } label: {
                    HStack(spacing: 12) {
                        Glyph(item.glyph, size: 20).foregroundStyle(Theme.secondaryInk)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 16))
                            if verticalSizeClass != .compact {
                                Text(item.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondaryInk)
                            .opacity(visited.contains(item.title) ? 1 : 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: verticalSizeClass == .compact ? 40 : 54)
                    .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
            }
            Text("They all live behind your tabs: swipe up on the bar.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .foregroundStyle(Theme.ink)
        .padding(6)
        .barSurface(cornerRadius: 20)
        .padding(.horizontal, 12)
        .frame(maxWidth: 480)
        .padding(.bottom, Theme.barHeight + 24)
    }

    // MARK: The receipt

    /// Only what really happened: a line that didn't is left off.
    private var receiptLines: [FirstMinuteReceipt.Line] {
        let cookies = SavedStats.totals.cookieBars - before.cookieBars
        var lines: [FirstMinuteReceipt.Line] = []
        if let opened = Onboarding.openedIn { lines.append(.init(what: "roko opened", value: opened)) }
        if let pageTook { lines.append(.init(what: "Page opened", value: pageTook)) }
        if cookies > 0 { lines.append(.init(what: "Cookie pop-ups answered", value: "\(cookies)")) }
        if let reading = summary?.readingTime { lines.append(.init(what: "Summary", value: reading)) }
        return lines
    }

    private var savedLine: String? {
        // A few seconds is true, but no total: it's left off until it's worth a line.
        let seconds = SavedStats.totals.seconds - before.seconds
        return seconds >= 30 ? SavedStats.duration(seconds) : nil
    }

    // MARK: Moving along

    /// The page you asked for is up, or on its way, arriving in the wake of the light.
    /// What's said about its speed is measured: its commit against the moment Go was tapped.
    private func pageOpened(at go: CFTimeInterval) {
        guard let tab = browser.selectedTab else { return }
        step = .opened
        showing = Task {
            if !reduceMotion {
                sweep = .up
                try? await Task.sleep(for: .milliseconds(60))
                sweep = .leaving
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
            // Only this page's commit counts: the launcher preloads for moments, not
            // minutes, so anything older is what this tab showed before. And a page
            // that hasn't started by now has nothing to boast of.
            @MainActor func commit() -> CFTimeInterval? { tab.committedAt > go - 20 ? tab.committedAt : nil }
            for _ in 0..<30 where commit() == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let took = commit().map { $0 - go }
            let speed = took.flatMap { $0 <= 0 ? "Loaded before you tapped Go." : $0 < 0.8 ? String(format: "Open in %.2f s.", $0) : nil }
            pageTook = took.flatMap { $0 <= 0 ? "before you tapped Go" : $0 < 0.8 ? String(format: "%.2f s", $0) : nil }
            fact = [speed, "Ads and pop-ups, already dealt with."].compactMap(\.self).joined(separator: " ")
            try? await Task.sleep(for: .seconds(1.2))
            sweep = .none
            try? await Task.sleep(for: .seconds(2.6))
            if Task.isCancelled { return }
            guard Self.canAsk else {
                step = .receipt
                return
            }
            if onStory { pull() } else { story() }
        }
    }

    /// Waits for a story, but not for ever.
    private func story() {
        step = .story
        showing = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled, step == .story { step = .receipt }
        }
    }

    /// The page itself shows the pull: it dips under a finger that isn't there, and
    /// comes back. A few times, then the guide lets it go.
    private func pull() {
        showing?.cancel()
        step = .pull
        showing = Task {
            for wait in [0.8, 3.4, 4.4] {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                if !reduceMotion, let tab = browser.selectedTab {
                    withAnimation(.easeOut(duration: 0.2)) { dipping = tab.showPull() }
                    try? await Task.sleep(for: .seconds(0.6))
                    withAnimation(.easeOut(duration: 0.2)) { dipping = false }
                }
            }
            try? await Task.sleep(for: .seconds(14))
            if !Task.isCancelled, step == .pull { step = .receipt }
        }
    }
}

/// roko's mark beside its words: it passes through an eclipse each time it speaks.
private struct GuideMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift = 0.12

    var body: some View {
        Eclipse(shift: reduceMotion ? 0.62 : shift)
            .fill(Theme.ink, style: FillStyle(eoFill: true))
            .frame(width: 16, height: 16)
            .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.15)) { shift = 0.62 } }
    }
}

/// What the first minute came to, printed up out of the bar a line at a time, each
/// line pushing the last one up as paper does. Every figure on it really happened.
/// A tap or a pull tears it off; left alone, it goes by itself.
struct FirstMinuteReceipt: View {
    struct Line: Identifiable {
        let what: String
        let value: String
        var id: String { what }
    }

    let lines: [Line]
    let saved: String?
    let still: Bool
    let done: () -> Void

    /// Printed so far: the title, the lines, the total, the tip.
    @State private var printed = 0
    @State private var torn = false
    @State private var pull: CGFloat = 0

    private var total: Int { lines.count + (saved == nil ? 2 : 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your first minute")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 2)
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if printed > index + 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(line.what).foregroundStyle(Theme.bodyInk)
                        Spacer(minLength: 8)
                        Text(line.value)
                            .foregroundStyle(Theme.ink)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.system(size: 14))
                    .transition(.printed)
                }
            }
            if let saved, printed > lines.count + 1 {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Time saved").font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 8)
                    Text(saved)
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(light: 0xB0601C, dark: 0xE8B98A))
                }
                .padding(.top, 6)
                .transition(.printed)
            }
            if printed >= total {
                Text("One more: hold the search bar and say what you want.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .transition(.printed)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16 + TornEdge.depth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            TornEdge().fill(Theme.panel)
                .overlay(TornEdge().stroke(Theme.edge))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 420)
        .offset(y: torn ? 700 : pull)
        // Out of the bar's edge, and back into it: never over the bar.
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipped()
        .padding(.bottom, Theme.barHeight + 12)
        .contentShape(.rect)
        .onTapGesture { tear() }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { pull = max($0.translation.height, 0) }
            .onEnded { value in
                if value.translation.height > 50 { tear() } else { withAnimation(.spring(duration: 0.35)) { pull = 0 } }
            })
        .sensoryFeedback(.impact(weight: .light), trigger: printed)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss") { tear() }
        .task {
            if still {
                printed = total
            } else {
                for line in 1...total {
                    try? await Task.sleep(for: .milliseconds(line == 1 ? 250 : 190))
                    withAnimation(.spring(duration: 0.3, bounce: 0.05)) { printed = line }
                }
            }
            AccessibilityNotification.Announcement("Your first minute").post()
            try? await Task.sleep(for: .seconds(9))
            tear()
        }
    }

    private func tear() {
        guard !torn else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.timingCurve(0.5, 0, 0.9, 0.5, duration: still ? 0.01 : 0.4)) { torn = true }
        Task {
            try? await Task.sleep(for: .seconds(still ? 0.02 : 0.42))
            done()
        }
    }
}

/// Paper with its foot torn off: square above, small even teeth below.
nonisolated struct TornEdge: Shape {
    static let depth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let teeth = max(Int((rect.width / 14).rounded()), 2)
        let step = rect.width / CGFloat(teeth)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 10))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 10, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 10, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 10), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - Self.depth))
        for tooth in stride(from: teeth, to: 0, by: -1) {
            let right = rect.minX + CGFloat(tooth) * step
            path.addLine(to: CGPoint(x: right - step / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: right - step, y: rect.maxY - Self.depth))
        }
        path.closeSubpath()
        return path
    }
}

private extension BrowserTab {
    /// The page, from its top, dipping as if pulled and coming back: the web view
    /// moved as one picture, so the page itself never knows. Whether it did.
    func showPull() -> Bool {
        guard let webView, !webView.scrollView.isTracking,
              webView.scrollView.contentOffset.y <= -webView.scrollView.adjustedContentInset.top + 1 else { return false }
        UIView.animate(withDuration: 0.42, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            webView.transform = CGAffineTransform(translationX: 0, y: 96)
        } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 0.25, options: [.curveEaseInOut, .allowUserInteraction]) {
                webView.transform = .identity
            }
        }
        return true
    }
}

private extension AnyTransition {
    /// A line on the receipt, once the paper has made room for it.
    static var printed: AnyTransition {
        .opacity.animation(.easeIn(duration: 0.12).delay(0.14))
    }
}
