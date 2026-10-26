import SwiftData
import SwiftUI

struct CommandItem: Identifiable {
    enum Action {
        case open(URL), switchTab(BrowserTab), openPin(Pin), search(String),
             browse(String), summarize, findOnPage, privateTab, settings, copy(String),
             pasteLink, openCopied(URL), todos, today, openApp(URL), ask(String), askAboutPage(String), addTodo(String, TodoWhen, DateComponents?),
             payParking(city: String, zone: String), extendParking, endParking
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let icon: Icon
    let action: Action
    /// A mark at the row's end in place of `kind` (a pin, for pinned pages).
    var mark: Glyph.Kind? = nil

    enum Icon {
        case glyph(Glyph.Kind), site(String), image(String)
    }
}

/// One field, one ranked list: addresses, searches, pins, open tabs, history,
/// suggestions and page actions. The field sits on top and the rows below it,
/// nearer the thumb, over the page frosted behind them (as Arc Search does).
/// The list snaps row by row like a picker: the row under the field is the
/// one Return runs, so a flick of the thumb chooses.
struct CommandBarView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \Pin.order) private var pins: [Pin]
    @Query(sort: \Todo.createdAt) private var todos: [Todo]
    /// Ticked in the bar a moment ago: still shown, struck through.
    @State private var justDone: Set<PersistentIdentifier> = []
    @State private var query = ""
    @State private var items: [CommandItem] = []
    @State private var suggestions: [String] = []
    /// "weather in London": London's weather, found for what was typed.
    @State private var placeWeather: (query: String, weather: TodayWeather)?
    /// Pinned town-weather answers, fetched as the bar opens.
    @State private var pinnedWeather: [String: TodayWeather] = PinnedAnswers.lastWeather
    @State private var selection = 0
    /// The row in the slot under the field, as the list is scrolled.
    @State private var topRow: String?
    /// Scrolled to a row other than the best match: the field shows that row,
    /// as Arc's does, so what Return will open is never a guess.
    @State private var previewing = false
    /// The list is being put back at its top by roko, not scrolled by you:
    /// the row it's going to, until it's there.
    @State private var resetTarget: String?
    /// Asks the list to go to a row (ScrollViewReader does it reliably).
    @State private var scrollRequest: String?
    @State private var hasCopiedLink = false
    /// The copied link itself, when roko may read it (see CopiedLink.peek).
    @State private var copiedURL: URL?
    /// Mid-blink of the private switch's eye.
    @State private var blink = false
    /// An answer was read this time the bar is open (see countAnswer).
    @State private var answerCounted = false
    /// What the rows were last built for.
    @State private var rowsQuery = ""
    @FocusState private var focused: Bool
    /// How tall the list is, between the field and the keyboard.
    @State private var listHeight: CGFloat = 300
    /// Grown out of the bar (true) or still sitting in it (false): see LauncherMorph.
    /// Kept by the app, not this view: a view rebuilt while the app starts up
    /// would otherwise come back half-drawn.
    private var opened: Bool { browser.launcherShown }
    /// The rows: in once the field has landed, so it never flies up through them.
    private var rowsShown: Bool { browser.launcherRows }
    /// A finger is on the list.
    @State private var listDragged = false
    /// The list is moving (dragged or still gliding): rows passing the slot tick.
    @State private var listMoving = false
    /// A row was swiped a moment ago: taps on rows wait till this has passed.
    @State private var swipeQuietUntil = Date.distantPast
    /// A light tick for each row that passes under the field, like a picker wheel.
    @State private var ticker = UISelectionFeedbackGenerator()
    /// Where the field ends up: at the top, under the status bar, as in Arc
    /// Search. Fixed, so it's known before anything is laid out and no keyboard
    /// (the system's, SwiftKey, one that says its size late) can move it.
    private var fieldTarget: CGRect {
        let screen = UIScreen.main.bounds
        return CGRect(x: 8, y: Self.safeTop + 8, width: screen.width - 16, height: 56)
    }

    /// How long the field takes to fly up, for what waits on it.
    private static let flight: Double = 0.2

    private static var safeTop: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return window?.safeAreaInsets.top ?? 59
    }

    /// Panel corner, and the row inset inside it. Rows round by the difference,
    /// so the two curves run parallel instead of a tight corner in a loose one.
    static let corner: CGFloat = 28
    static let inset: CGFloat = 8

    var body: some View {
        ZStack(alignment: .top) {
            // The page stays in view, frosted and dimmed in its own colours:
            // what's typed is about it. A tap on it closes the bar.
            Rectangle()
                .fill(.ultraThinMaterial)
                // Deep enough that a white page reads as dusk, not grey.
                .overlay(Theme.canvas.opacity(0.66))
                .ignoresSafeArea()
                .opacity(opened ? 1 : 0)
                .contentShape(.rect)
                .onTapGesture { dismiss() }
                // A swipe down anywhere on the page closes the bar too.
                .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                    if value.translation.height > 50 { dismiss() }
                })

            VStack(spacing: 6) {
                field
                    .modifier(LauncherMorph(from: browser.launcherOrigin, to: fieldTarget, opened: opened))
                    .zIndex(1)
                    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                        if value.translation.height > 60 { dismiss() }
                    })
                // Down to the keyboard, whatever its size, settling as it arrives.
                results
                    .opacity(rowsShown ? 1 : 0)
                    .offset(y: rowsShown ? 0 : -10)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .onAppear {
            query = browser.commandPrefill
            rebuild()
            open()
        }
        .onDisappear {
            browser.launcherShown = false
            browser.launcherRows = false
        }
        .task {
            guard browser.launcherContext == .web, await CopiedLink.isWaiting() else { return }
            copiedURL = await CopiedLink.peek()
            // The page you're on isn't worth a row.
            if let copiedURL, browser.isCurrentPage(copiedURL) { return }
            hasCopiedLink = true
            rebuild()
        }
        // Offered once: closed without pasting it, it isn't offered again.
        .onDisappear { if hasCopiedLink { CopiedLink.took() } }
        .onChange(of: query) {
            selection = 0
            rebuild()
            // Typing starts the list over at its best match.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { backToTop() }
        }
        .onChange(of: topRow) { _, row in
            // Scrolled: the row now in the slot is the one Return runs, and the field shows it.
            if let target = resetTarget {
                if row == target { resetTarget = nil }
                previewing = false
                return
            }
            guard let row, let index = items.firstIndex(where: { $0.id == row }) else {
                previewing = false
                return
            }
            selection = index
            withAnimation(.snappy(duration: 0.18)) { previewing = index > 0 || query.isEmpty }
        }
        .onChange(of: CurrencyRates.shared.date) { rebuild() }
        .onChange(of: TodayModel.shared.weather) { rebuild() }
        // Speaking: the words come into the field as they're heard, and the rows follow.
        .onChange(of: VoiceInput.shared.partial) { _, heard in
            if browser.voiceListening { query = heard }
        }
        // Done listening: the keyboard, to fix or add to what was heard.
        .onChange(of: browser.voiceListening) { _, listening in
            if !listening, browser.panel == .command { focused = true }
        }
        .onChange(of: browser.voiceResult) { _, said in
            guard let said else { return }
            query = said
            browser.voiceResult = nil
        }
        .task(id: query) {
            // "parking": where you are, in zones (a precise fix, once a minute at most).
            guard ParkingQuery.matches(query) else { return }
            await Parking.shared.locate()
            rebuild()
        }
        .onChange(of: Parking.shared.session) { rebuild() }
        .task(id: query) {
            // "weather in London", "vrijeme u Zagrebu": a town's weather, after a short pause.
            guard WeatherQuery.place(in: query) != nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let weather = await WeatherQuery.weather(for: query), !Task.isCancelled else { return }
            placeWeather = (query, weather)
            rebuild()
        }
        .task {
            // Pinned town weather: all at once, as the bar opens.
            await withTaskGroup(of: (String, TodayWeather?).self) { group in
                // Half an hour old or less: what's there stands (two requests a town saved).
                for asked in PinnedAnswers.all where WeatherQuery.place(in: asked) != nil
                    && Date.now.timeIntervalSince(pinnedWeather[asked]?.fetchedAt ?? .distantPast) > 1800 {
                    group.addTask { (asked, await WeatherQuery.weather(for: asked)) }
                }
                for await (asked, weather) in group {
                    if let weather {
                        pinnedWeather[asked] = weather
                        PinnedAnswers.lastWeather[asked] = weather
                    }
                }
            }
            rebuild()
        }
        .task(id: query) {
            // A short pause so suggestions aren't requested for every keystroke.
            let text = query.trimmingCharacters(in: .whitespaces)
            guard browser.launcherContext == .web, UserDefaults.standard.object(forKey: "suggestions") as? Bool ?? true,
                  text.count >= 2, Omnibox.url(from: text) == nil else {
                suggestions = []
                return
            }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let fetched = await SearchEngine.current.fetchSuggestions(for: text)
            guard !Task.isCancelled else { return }
            suggestions = Array(fetched.filter { $0.lowercased() != text.lowercased() }.prefix(4))
            rebuild()
        }
    }

    // MARK: Layout

    private var results: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 2) {
                // Best match first, right under the field.
                if browser.launcherContext == .todo && query.isEmpty && !dueTodos.isEmpty { todoWidget }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        if case .pasteLink = item.action {
                            copiedLinkRow
                        } else {
                            Button {
                                // A swipe that ends on the row isn't a tap on it.
                                guard Date.now > swipeQuietUntil else { return }
                                perform(item)
                            } label: {
                                CommandRow(item: item, isSelected: index == selection && (!query.isEmpty || previewing))
                            }
                            .buttonStyle(.plain)
                            // From history: swipe it away to the left to forget it.
                            .modifier(SwipeToForget(enabled: Self.forgettable(item) != nil,
                                                    swiping: { swipeQuietUntil = .now.addingTimeInterval(0.6) }) {
                                if let (url, wholeSite) = Self.forgettable(item) { forget(url, wholeSite: wholeSite) }
                            })
                        }
                    }
                    .id(item.id)
                    .contextMenu {
                        if case .openPin(let pin) = item.action {
                            Button("Unpin", role: .destructive) {
                                browser.unpin(pin)
                                rebuild()
                            }
                        } else if let (url, wholeSite) = Self.forgettable(item) {
                            Button(role: .destructive) { forget(url, wholeSite: wholeSite) } label: {
                                Label(wholeSite ? "Remove Site from History" : "Remove from History", systemImage: "trash")
                            }
                        } else if item.id.hasPrefix("answer-") {
                            Button("Unpin", role: .destructive) {
                                PinnedAnswers.remove(String(item.id.dropFirst("answer-".count)))
                                rebuild()
                            }
                        } else if ["calc", "weather", "weather-place", "calendar"].contains(item.id) || item.id.hasPrefix("parking-zone") {
                            // An answer kept with your pins, worked out again each time.
                            Button {
                                PinnedAnswers.add(query.trimmingCharacters(in: .whitespaces))
                                browser.showToast("Pinned")
                            } label: { Label("Pin", systemImage: "pin") }
                        }
                    }
                    // Typing "todo" brings today's to-dos up under the To-do row, to tick off there.
                    if item.id == "action-todos" && !dueTodos.isEmpty { todoWidget }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Self.inset - 4)
        }
        // Row by row, like a picker; any row can be brought up to the slot.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $topRow, anchor: .top)
        // Room below the last row, so any row can come up to the slot under the field.
        .contentMargins(.bottom, max(0, listHeight - 64), for: .scrollContent)
        .scrollIndicators(.hidden)
        // Rows leaving at either edge fade rather than being sliced off.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 6)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
            }
        }
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        // Pulled down past its top by a finger, the list closes the bar, as a sheet
        // would. Only by a finger: while the list lays itself out it can pass
        // that point on its own, which closed the bar the moment it opened.
        .onScrollPhaseChange { _, phase in
            listDragged = phase == .interacting
            listMoving = phase != .idle
            if listMoving { ticker.prepare() }
        }
        // Which row is passing the slot, in row heights scrolled; each change ticks.
        .onScrollGeometryChange(for: Int.self) { geometry in
            Int(((geometry.contentOffset.y + geometry.contentInsets.top) / 62).rounded())
        } action: { old, new in
            if listMoving, new != old, new >= 0, Preferences.launcherTicks { ticker.selectionChanged() }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 60
        } action: { _, pulled in
            if pulled, listDragged { dismiss() }
        }
        .onChange(of: scrollRequest) { _, target in
            guard let target else { return }
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
            scrollRequest = nil
        }
        }
    }

    /// A link copied a moment ago that roko can't read without iOS asking: a
    /// row like the others, with the system Paste button where the kind goes.
    private var copiedLinkRow: some View {
        HStack(spacing: 12) {
            Glyph(.link, size: 18).foregroundStyle(Theme.secondaryInk).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Link you copied")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                Text("From your clipboard")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            PasteControl { url in
                focused = false
                browser.openFromCommandBar(url)
            }
        }
        // "Paste" ends where the other rows' kind labels do.
        .padding(.leading, 12)
        .padding(.trailing, 12 - PasteControl.inset)
        .padding(.vertical, 4)
    }

    private var dueTodos: [Todo] {
        todos.filter { $0.isDueNow || justDone.contains($0.persistentModelID) }.sorted(by: Todo.listOrder)
    }

    /// Today's to-dos, under the To-do row: tick them off without opening the
    /// list (the row opens it). Four at most; the rest are counted.
    private var todoWidget: some View {
        let due = dueTodos
        let shown = due.prefix(4)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown)) { todo in
                HStack(spacing: 12) {
                    Button { toggle(todo) } label: {
                        TodoCircle(done: todo.done)
                            .frame(width: 44, height: 40)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22)
                    .accessibilityLabel(todo.done ? "Done" : "Not done")
                    Text(todo.title)
                        .font(.system(size: 16))
                        .foregroundStyle(todo.done ? Theme.secondaryInk : Theme.ink)
                        .strikethrough(todo.done, color: Theme.secondaryInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let time = todo.timeLabel {
                        Text(time)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.faintInk)
                    }
                }
                .padding(.horizontal, 12)
                .transition(.opacity)
            }
            if due.count > shown.count {
                Text("\(due.count - shown.count) more")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.leading, 46)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.3), value: due.map(\.persistentModelID))
    }

    private func toggle(_ todo: Todo) {
        let id = todo.persistentModelID
        withAnimation(.snappy(duration: 0.25)) {
            todo.done.toggle()
            todo.doneAt = todo.done ? .now : nil
            if todo.done { justDone.insert(id) } else { justDone.remove(id) }
        }
        try? context.save()
        guard todo.done else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard todo.done else { return }
            _ = withAnimation(.snappy(duration: 0.35)) { justDone.remove(id) }
        }
    }

    private var field: some View {
        HStack(spacing: 12) {
            // While typing hides the switch, the leading mark keeps private mode visible.
            let showsPrivate = browser.commandMode == .privateTab && !query.isEmpty
            let shown = previewing ? items[safe: selection] : nil
            Group {
                if let shown {
                    RowIcon(icon: shown.icon)
                } else {
                    if browser.voiceListening {
                        // Listening: the mark breathes with the voice; a tap stops it.
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .scaleEffect(1 + VoiceInput.shared.level * 0.35)
                            .animation(.easeOut(duration: 0.08), value: VoiceInput.shared.level)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                            .onTapGesture { browser.finishVoice() }
                            .accessibilityLabel("Stop listening")
                    } else {
                        Glyph(showsPrivate ? .eyeClosed : contextGlyph, size: 18)
                            .foregroundStyle(showsPrivate ? Theme.accent : Theme.secondaryInk)
                    }
                }
            }
            .frame(width: 22)
            TextField(placeholder, text: $query)
                // Scrolled to a row: it shows here in place of what was typed,
                // which comes back with the next key.
                .opacity(shown == nil ? 1 : 0)
                .overlay(alignment: .leading) {
                    if let shown {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(shown.title)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.ink)
                            if !shown.subtitle.isEmpty {
                                Text(shown.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                // Autocorrect turns "theverge.com" into "the verge.com", a search.
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    // Return right on the last key: the rows may still be the
                    // ones for one letter less ("Call the ban"). Build them now.
                    if !previewing, rowsQuery != query {
                        rebuild()
                        selection = 0
                    }
                    guard !query.trimmingCharacters(in: .whitespaces).isEmpty || previewing,
                          let item = items[safe: selection] else { return }
                    perform(item)
                }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !query.isEmpty || previewing {
                Button {
                    if query.isEmpty {
                        // Only a scrolled-to row showing: back to the top.
                        backToTop()
                    } else {
                        query = ""
                    }
                } label: {
                    // A filled disc so it reads as a control at a glance; the
                    // whole 44-point square is tappable, not just the mark.
                    Circle()
                        .fill(Theme.secondaryInk.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .overlay { Glyph(.close, size: 10, weight: 2.4).foregroundStyle(Theme.panel) }
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .transition(.opacity)
            } else {
                // Same spot: the private switch while empty, the clear button once typing.
                if browser.launcherContext == .web {
                    privateSwitch
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
        .animation(.easeOut(duration: 0.15), value: previewing)
        // Icons share one axis with the rows' icons below.
        .padding(.horizontal, 16)
        .frame(height: 56)
        // What's in it comes in once it has nearly grown; the shape itself is the morph.
        .opacity(opened ? 1 : 0)
        .animation(opened ? .easeOut(duration: 0.18).delay(0.16) : .easeIn(duration: 0.1), value: opened)
        .background {
            // Scaled from the capsule, the corners start at the capsule's roundness.
            RoundedRectangle(cornerRadius: opened ? 18 : 28)
                .fill(opened ? Theme.panel : Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: opened ? 18 : 28).strokeBorder(Theme.edge.opacity(opened ? 1 : 0)))
        }
    }

    /// Arc-style private switch: an open eye, which blinks shut (in the accent)
    /// for private, and blinks open again for a normal tab.
    private var privateSwitch: some View {
        let isPrivate = browser.commandMode == .privateTab
        return Button {
            // Lids close on the old eye, the new one opens.
            withAnimation(.easeIn(duration: 0.09)) { blink = true } completion: {
                browser.commandMode = isPrivate ? .newTab : .privateTab
                withAnimation(.easeOut(duration: 0.14)) { blink = false }
            }
        } label: {
            Glyph(isPrivate ? .eyeClosed : .eye, size: 22)
                .foregroundStyle(isPrivate ? Theme.accent : Theme.secondaryInk)
                .scaleEffect(x: 1, y: blink ? 0.12 : 1)
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .sensoryFeedback(.selection, trigger: isPrivate)
        .buttonStyle(.plain)
        .accessibilityLabel("Private")
        .accessibilityValue(isPrivate ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private var placeholder: String {
        if browser.voiceListening { return "Listening, in English or Croatian…" }
        switch browser.launcherContext {
        case .todo: return "New to-do, e.g. Call Petra on Monday at 15"
        case .followUp: return "Ask a follow-up"
        case .aboutPage: return "Ask about this page"
        case .web:
            switch browser.commandMode {
            case .privateTab: return "Private search or address"
            case .currentTab, .newTab: return "Search or enter address"
            }
        }
    }

    /// The field's mark: what typing here does.
    private var contextGlyph: Glyph.Kind {
        switch browser.launcherContext {
        case .web: .search
        case .todo: .todo
        case .followUp, .aboutPage: .browse
        }
    }

    /// The top of the list: the pins with nothing typed, else the best match.
    private func backToTop() {
        previewing = false
        selection = 0
        guard let top = items.first?.id, topRow != top else { return }
        resetTarget = top
        scrollRequest = top
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        selection = min(max(selection + step, 0), items.count - 1)
        scrollRequest = items[selection].id
        ticker.selectionChanged()
        return .handled
    }

    /// Out of the bar: the field grows from the capsule up to its place, and
    /// only then does the keyboard come, rising under it, so the keyboard never
    /// covers the capsule the field is growing out of.
    private func open() {
        answerCounted = false
        Parking.shared.clearIfOver()
        if PinnedAnswers.all.contains(where: ParkingQuery.matches) {
            Task {
                await Parking.shared.locate()
                rebuild()
            }
        }
        // Opened with no capsule to grow from (on launch, with nothing open): just there.
        guard browser.launcherOrigin != .zero else {
            browser.launcherShown = true
            browser.launcherRows = true
            focused = !browser.voiceListening
            return
        }
        // A frame later: drawn in the bar's place first, so there's somewhere to grow from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.launcher) { browser.launcherShown = true }
            withAnimation(.easeOut(duration: 0.12).delay(Self.flight * 0.55)) { browser.launcherRows = true }
            // Listening, there's no keyboard: the rows have the room.
            if !browser.voiceListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
            }
        }
    }

    /// Back into the bar: the field shrinks into the capsule it came from,
    /// then the launcher is gone and the capsule is there in its place.
    private func dismiss() {
        // Closed on a typed answer (a sum, a rate, the weather): read, so it counts.
        if !query.isEmpty, let top = items.first(where: { $0.id == topRow }) ?? items.first,
           !top.id.hasPrefix("answer-") {
            countAnswer(top)
        }
        browser.cancelVoice()
        focused = false
        withAnimation(.easeIn(duration: 0.1)) { browser.launcherRows = false }
        withAnimation(.launcher) { browser.launcherShown = false } completion: {
            // Something else opened meanwhile (a notification, Today in the
            // morning, a summary): that stays.
            guard browser.panel == .command else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { browser.panel = browser.launcherReturn }
        }
    }

    // MARK: Ranking

    /// What the launcher offers on a screen other than a page: the to-do
    /// being typed, a follow-up to ask (or the answer's suggested ones), a
    /// question about the summarized page.
    private func contextRows() -> [CommandItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        switch browser.launcherContext {
        case .web:
            return []
        case .todo:
            guard let read = TodoDraft.read(text), !read.title.isEmpty else { return [] }
            let when = read.when ?? .today
            return [CommandItem(id: "add-todo", title: read.title, subtitle: "New to-do for " + TodoDraft.phrase(when, read.time),
                                kind: "Add", icon: .glyph(.todo), action: .addTodo(read.title, when, read.time))]
        case .followUp:
            if !text.isEmpty {
                return [CommandItem(id: "ask", title: text, subtitle: "Ask a follow-up", kind: "AI",
                                    icon: .glyph(.browse), action: .ask(text))]
            }
            // Nothing typed: what the answer suggests asking next.
            return (browser.browseForMe?.latest.followUps ?? []).map {
                CommandItem(id: "suggested-\($0)", title: $0, subtitle: "", kind: "", icon: .glyph(.browse), action: .ask($0))
            }
        case .aboutPage:
            guard !text.isEmpty else { return [] }
            return [CommandItem(id: "ask", title: text, subtitle: "Ask about this page", kind: "AI",
                                icon: .glyph(.browse), action: .askAboutPage(text))]
        }
    }

    /// A row that comes from history (a page you were on, or a site you've
    /// been to): it can be forgotten.
    static func forgettable(_ item: CommandItem) -> (URL, Bool)? {
        guard case .open(let url) = item.action else { return nil }
        if item.id.hasPrefix("history-") || item.id.hasPrefix("recent-") { return (url, false) }
        if item.id.hasPrefix("site-") { return (url, true) }
        return nil
    }

    private func forget(_ url: URL, wholeSite: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            browser.forget(url, wholeSite: wholeSite)
            rebuild()
        }
        browser.showToast(wholeSite ? "Site removed from history" : "Removed from history")
    }

    /// Parking, in a city roko pays in. Running: the time left, and a tap adds
    /// an hour. Otherwise the zone you're in, one row a zone when you're on a
    /// border, ready to write the text. Nothing outside those cities.
    static func parkingRows(typed: Bool) -> [CommandItem] {
        let parking = Parking.shared
        let car = CommandItem.Icon.glyph(.car)
        if let session = parking.active, let zone = session.zone {
            let left = SavedStats.duration(session.endsAt.timeIntervalSinceNow.rounded(.up))
            var rows = [CommandItem(id: "parking-running", title: "\(zone.name) · \(left) left",
                                    subtitle: "Paid until \(session.endsAt.formatted(date: .omitted, time: .shortened)) · \(Parking.display(session.plate))",
                                    kind: parking.canExtend ? "Add an hour" : "", icon: car, action: .extendParking)]
            if typed {
                rows.append(CommandItem(id: "parking-end", title: "End the parking timer", subtitle: "What's paid stays paid",
                                        kind: "", icon: .glyph(.close), action: .endParking))
            }
            return rows
        }
        guard let match = parking.match else {
            return parking.noZoneHere && typed
                // Not "free here": the city's zones grow faster than the map, so the sign decides.
                ? [CommandItem(id: "parking-none", title: "No paid zone found here", subtitle: "Check the signs · roko knows Osijek's zones 0 and I",
                               kind: "", icon: car, action: .search("parking"))]
                : []
        }
        let city = match.city
        guard city.chargingEnds(after: .now) != nil else {
            return [CommandItem(id: "parking-free", title: "Parking is free now", subtitle: "\(city.name) charges \(city.hoursLine)",
                                kind: "", icon: car, action: .search("parking"))]
        }
        guard let plate = parking.plates.first else {
            return [CommandItem(id: "parking-zone-\(match.zones[0].code)", title: "\(match.zones[0].name) · \(match.zones[0].price) an hour",
                                subtitle: "Add your registration in Settings to pay by text",
                                kind: "Settings", icon: car, action: .settings)]
        }
        let border = match.zones.count > 1
        return match.zones.map { zone in
            let limit = zone.maxMinutesPerDay.map { " · \($0 / 60) h a day" } ?? ""
            return CommandItem(id: "parking-zone-\(zone.code)", title: "\(zone.name) · \(zone.price) an hour",
                               subtitle: (border ? "Zone border, check the sign · " : "")
                                   + "\(Parking.display(plate)) to \(zone.number)" + limit,
                               kind: "Pay", icon: car, action: .payParking(city: city.id, zone: zone.code))
        }
    }

    /// A weather answer: now, the day under it.
    static func weatherRow(id: String, _ weather: TodayWeather, action: CommandItem.Action) -> CommandItem {
        CommandItem(id: id, title: "\(Int(weather.temperature.rounded()))° " + weather.condition + (weather.place.map { " in \($0)" } ?? ""),
                    subtitle: weather.dayLine, kind: "Weather", icon: .image("phosphor/\(weather.glyph)"), action: action)
    }

    private func rebuild() {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            if LaunchClock.isEnabled {
                print(String(format: "PERF rank \"%@\" %.1fms, %d rows", query, (CFAbsoluteTimeGetCurrent() - started) * 1000, items.count))
            }
        }
        rowsQuery = query
        guard browser.launcherContext == .web else {
            items = contextRows()
            return
        }
        items = CommandRanker.rank(query: query, browser: browser, suggestions: suggestions)
        // A town's weather, asked for by name: first, as the answer.
        if let (asked, weather) = placeWeather, asked == query, WeatherQuery.place(in: query) != nil {
            items.insert(Self.weatherRow(id: "weather-place", weather, action: .search(query)), at: 0)
        }
        // "parking" in a city roko pays in: your zone, ready to pay, or the time left.
        if ParkingQuery.matches(query) {
            items.insert(contentsOf: Self.parkingRows(typed: true), at: 0)
        }
        // Asked for the weather and it's half an hour old: fetch it now (one small request).
        if items.contains(where: { $0.id == "weather" }),
           Date.now.timeIntervalSince(TodayModel.shared.weather?.fetchedAt ?? .distantPast) > 1800 {
            Task { await TodayModel.shared.freshenWeather() }
        }
        // Nothing typed yet: a link copied a moment ago, here or on a Mac,
        // today's to-dos while any are left, your pins (as Arc lists them),
        // then the last pages you were on, to scroll through and pick.
        if query.isEmpty {
            var rows: [CommandItem] = []
            // Paid parking running: the time left comes before anything else.
            if Parking.shared.active != nil {
                rows.append(contentsOf: Self.parkingRows(typed: false))
            }
            if hasCopiedLink {
                rows.append(copiedURL.map {
                    CommandItem(id: "copied-link", title: $0.shortDisplay, subtitle: "Link you copied",
                                kind: "", icon: .site($0.displayHost), action: .openCopied($0))
                } ?? CommandItem(id: "copied-link", title: "Link you copied", subtitle: "",
                                 kind: "", icon: .glyph(.link), action: .pasteLink))
            }
            let left = todos.filter(\.isDueNow).count
            if left > 0 {
                rows.append(CommandItem(id: "todos-today", title: "To-do",
                                        subtitle: left == 1 ? "One left for today" : "\(left) left for today",
                                        kind: "", icon: .glyph(.todo), action: .todos))
            }
            // Pinned answers, worked out again now: the weather, days until, a rate.
            for asked in PinnedAnswers.all {
                let answer: CommandItem?
                if ParkingQuery.matches(asked) {
                    // Running, it's already on top; otherwise the zone you're in.
                    guard Parking.shared.active == nil else { continue }
                    answer = Self.parkingRows(typed: false).first
                } else if WeatherQuery.place(in: asked) != nil {
                    answer = pinnedWeather[asked].map { Self.weatherRow(id: "", $0, action: .search(asked)) }
                        ?? CommandItem(id: "", title: "Weather", subtitle: asked, kind: "", icon: .glyph(.today), action: .search(asked))
                } else if ["calendar", "kalendar", "next", "next meeting", "agenda", "raspored"].contains(asked.lowercased()) {
                    answer = CommandRanker.calendarItem()
                } else if ["weather", "forecast", "vrijeme", "vreme", "prognoza"].contains(asked.lowercased()),
                          let weather = TodayModel.shared.weather {
                    answer = Self.weatherRow(id: "", weather, action: .today)
                } else {
                    // A sum, a conversion, days until: the calculator alone, not the whole ranking.
                    answer = Calculator.answer(asked).map {
                        CommandItem(id: "", title: $0.result, subtitle: $0.question, kind: "", icon: .glyph(.equals), action: .copy($0.result))
                    }
                }
                guard let answer else { continue }
                rows.append(CommandItem(id: "answer-\(asked)", title: answer.title, subtitle: answer.subtitle,
                                        kind: "", icon: answer.icon, action: answer.action, mark: .pin))
            }
            // The same answers, for the Answer widget on the Home or Lock Screen.
            WidgetBridge.setAnswers(rows.compactMap { row in
                guard row.id.hasPrefix("answer-") else { return nil }
                let icon: String? = switch row.icon {
                case .image(let name): name
                case .glyph(let kind): "phosphor/\(kind.rawValue)"
                case .site: nil
                }
                return (String(row.id.dropFirst("answer-".count)), row.title, row.subtitle, icon)
            })
            var seen = Set<String>()
            for pin in pins {
                guard let url = URL(string: pin.url) else { continue }
                seen.insert(pin.url)
                rows.append(CommandItem(id: "pin-\(pin.url)", title: pin.title.isEmpty ? pin.host : pin.title,
                                        subtitle: url.displayHost, kind: "", icon: .site(pin.host),
                                        action: .openPin(pin), mark: .pin))
            }
            let firstRecent = rows.count
            for entry in browser.history(matching: "", limit: 30) {
                guard rows.count - firstRecent < 8, let url = URL(string: entry.url), !browser.isCurrentPage(url),
                      seen.insert(entry.url).inserted else { continue }
                rows.append(CommandItem(id: "recent-\(entry.url)", title: entry.title.isEmpty ? url.displayHost : entry.title,
                                        subtitle: url.displayHost, kind: "", icon: .site(url.displayHost), action: .open(url)))
            }
            items = rows
        }
        // Resolve where Return would go before it's pressed.
        switch items.first?.action {
        case .open(let url): DNSPrefetcher.warm(url.host())
        case .openPin(let pin): DNSPrefetcher.warm(URL(string: pin.url)?.host())
        case .search(let text): DNSPrefetcher.warm(SearchEngine.current.searchURL(for: text).host())
        default: break
        }
    }

    /// An answer read in the bar, for Settings' count of time saved: once
    /// each time the bar is open. Seconds it would take another way: the
    /// Weather app or a search, a calculator or a rate looked up, Calendar.
    private func countAnswer(_ item: CommandItem) {
        guard !answerCounted, let seconds = Self.answerSeconds(item) else { return }
        answerCounted = true
        SavedStats.instantAnswer(seconds: seconds)
    }

    static func answerSeconds(_ item: CommandItem) -> Double? {
        let weatherWords = ["weather", "forecast", "vrijeme", "vreme", "prognoza"]
        let calendarWords = ["calendar", "kalendar", "next", "next meeting", "agenda", "raspored"]
        if item.id.hasPrefix("answer-") {
            let asked = String(item.id.dropFirst(7)).lowercased()
            if weatherWords.contains(asked) || WeatherQuery.place(in: asked) != nil { return 20 }
            return calendarWords.contains(asked) ? 10 : 12
        }
        switch item.id {
        case "calc": return 12
        case "calendar": return 10
        case _ where item.id.hasPrefix("weather"): return 20
        default: return nil
        }
    }

    private func perform(_ item: CommandItem) {
        focused = false
        countAnswer(item)
        switch item.action {
        case .open(let url): browser.openFromCommandBar(url)
        case .switchTab(let tab): browser.select(tab); browser.panel = .none
        case .openPin(let pin): browser.open(pin)
        case .search(let text): browser.openFromCommandBar(SearchEngine.current.searchURL(for: text))
        case .browse(let text): browser.browse(for: text)
        case .summarize: browser.summarize()
        case .findOnPage:
            browser.panel = .none
            browser.selectedTab?.webView?.findInteraction?.presentFindNavigator(showingReplace: false)
        case .privateTab: browser.showCommandBar(mode: .privateTab)
        case .settings: browser.panel = .settings
        case .todos: browser.panel = .todos
        case .today: browser.panel = .today
        case .openApp(let url):
            browser.panel = .none
            UIApplication.shared.open(url)
        case .addTodo(let title, let when, let time):
            let todo = Todo(title: title, when: when, at: time)
            todo.order = (todos.map(\.order).max() ?? 0) + 1
            context.insert(todo)
            try? context.save()
            if time != nil { TodoAlerts.askIfNeeded() }
            browser.showToast(when == .today && time == nil ? "Added to today's to-dos"
                              : "To-do added for \(TodoDraft.phrase(when, time))")
            if browser.launcherContext == .todo {
                // In To-do: ready for the next one, the list showing it behind.
                query = ""
                focused = true
            } else {
                browser.panel = .none
            }
        case .ask(let question):
            browser.panel = .none
            browser.browseForMe?.ask(question)
        case .askAboutPage(let question):
            browser.panel = .none
            if let summary = browser.summary { browser.ask(question, about: summary) }
        case .payParking(let cityID, let code):
            guard let city = ParkingCity.with(id: cityID), let zone = city.zone(code) else { break }
            browser.panel = .none
            Parking.shared.pay(zone, in: city)
        case .extendParking:
            browser.panel = .none
            Parking.shared.extend()
        case .endParking:
            Parking.shared.end()
            browser.showToast("Parking timer ended")
            rebuild()
        case .copy(let result):
            UIPasteboard.general.string = result
            CopiedLink.copiedInRoko()
            browser.panel = .none
            browser.showToast("Copied \(result)")
        case .pasteLink:
            break  // its row has the system Paste button instead
        case .openCopied(let url):
            CopiedLink.took()
            browser.openFromCommandBar(url)
        }
    }
}

/// A row's mark: a glyph, or the site's own icon.
private struct RowIcon: View {
    let icon: CommandItem.Icon

    var body: some View {
        switch icon {
        case .glyph(let kind): Glyph(kind, size: 18).foregroundStyle(Theme.secondaryInk)
        case .site(let host): SiteIcon(host: host, size: 18)
        case .image(let name):
            Image(name).resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(Theme.ink)
        }
    }
}

private struct CommandRow: View {
    let item: CommandItem
    let isSelected: Bool

    private var isAnswer: Bool {
        if case .copy = item.action { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(icon: item.icon)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(isAnswer ? .system(size: 26, weight: .semibold).monospacedDigit() : .system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    // Only an answer shrinks to fit; a long page title just truncates.
                    .minimumScaleFactor(isAnswer ? 0.6 : 1)
                    .textSelection(.disabled)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let mark = item.mark {
                Glyph(mark, size: 14).foregroundStyle(Theme.faintInk)
            } else {
                Text(item.kind)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faintInk)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Theme.selection : .clear,
                    in: .rect(cornerRadius: CommandBarView.corner - CommandBarView.inset))
        .contentShape(.rect)
    }
}

enum CommandRanker {
    /// What's next on your calendar, as a row; Return opens Calendar there.
    static func calendarItem() -> CommandItem {
        let item: CommandItem
        if !TodayCalendar.isAllowed {
            item = CommandItem(id: "calendar", title: "Calendar", subtitle: "Allow it in Today", kind: "Today",
                               icon: .glyph(.calendar), action: .today)
        } else if let event = TodayCalendar.next() {
            let place = event.location.map { " · \($0)" } ?? ""
            item = CommandItem(id: "calendar", title: event.title, subtitle: TodayCalendar.when(event) + place,
                               kind: "Calendar", icon: .glyph(.calendar),
                               action: .openApp(URL(string: "calshow:\(Int(event.start.timeIntervalSinceReferenceDate))")!))
        } else {
            item = CommandItem(id: "calendar", title: "Nothing on your calendar", subtitle: "For the next seven days",
                               kind: "Calendar", icon: .glyph(.calendar),
                               action: .openApp(URL(string: "calshow:\(Int(Date.now.timeIntervalSinceReferenceDate))")!))
        }
        return item
    }

    /// The row for a site called what was typed: a tab, pin, history page or
    /// well-known site whose title starts with it as whole words, the one
    /// with the shortest address first.
    static func siteNamed(_ needle: String, in items: [CommandItem]) -> CommandItem? {
        let candidates = items.filter { item in
            let title = item.title.lowercased()
            guard title.hasPrefix(needle) else { return false }
            let rest = title.dropFirst(needle.count)
            guard rest.isEmpty || rest.first.map({ !$0.isLetter }) == true else { return false }
            switch item.action {
            case .open, .switchTab, .openPin: return true
            default: return false
            }
        }
        func address(_ item: CommandItem) -> Int {
            switch item.action {
            case .open(let url): return url.path.count
            case .switchTab(let tab): return tab.url?.path.count ?? 99
            case .openPin(let pin): return URL(string: pin.url)?.path.count ?? 99
            default: return 99
            }
        }
        return candidates.min { address($0) < address($1) }
    }

    static func rank(query rawQuery: String, browser: BrowserModel, suggestions: [String]) -> [CommandItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let needle = query.lowercased()
        let pins = browser.pins()

        // Nothing typed: just your pins, in their own row above the field.
        // Open pages show up only once they match what you type.
        guard !query.isEmpty else { return [] }

        var ranked: [(score: Int, item: CommandItem)] = []

        // "todo call Petra tomorrow": a new to-do, on top, so Return adds it.
        if let draft = TodoDraft.parse(query) {
            ranked.append((1020, CommandItem(id: "add-todo", title: draft.title, subtitle: "New to-do",
                                             kind: TodoDraft.label(draft.when, draft.time), icon: .glyph(.todo),
                                             action: .addTodo(draft.title, draft.when, draft.time))))
        }

        // A sum, conversion or time question gets answered on top, Raycast-style.
        let calculation = Calculator.answer(query)
        if let answer = calculation {
            ranked.append((1000, CommandItem(id: "calc", title: answer.result, subtitle: answer.question,
                                             kind: "Copy", icon: .glyph(.equals), action: .copy(answer.result))))
        }

        // The literal reading of what was typed.
        let literalURL = Omnibox.url(from: query)
        if let url = literalURL {
            ranked.append((900, CommandItem(id: "open-\(url)", title: url.displayHost, subtitle: url.absoluteString,
                                            kind: "Open", icon: .glyph(.openLink), action: .open(url))))
        } else {
            ranked.append((900, CommandItem(id: "search-\(query)", title: query, subtitle: "Search \(SearchEngine.current.name)",
                                            kind: "Search", icon: .glyph(.search), action: .search(query))))
            // A question, not a word: one word is usually an address being typed.
            // Not when the calculator already answered it ("25$ in €").
            if query.contains(" "), calculation == nil {
                // A question, a comparison or a decision is better answered than
                // searched: then Browse for Me goes first, so Return runs it,
                // with the plain search right under it.
                let score = ResearchDepth.prefersAnswer(query) ? 905 : 850
                // Says what it does; the question itself is already in the field.
                ranked.append((score, CommandItem(id: "browse-\(query)", title: "Browse for me", subtitle: "Reads the web and answers",
                                                kind: "AI", icon: .glyph(.browse), action: .browse(query))))
                // Or keep it: what was typed becomes a to-do ("call Petra tomorrow" for tomorrow).
                // When it reads like one ("call Petra tomorrow", "kupiti mlijeko"), it's
                // the first row, so Return adds it, as Browse for Me goes first for a question.
                if TodoDraft.parse(query) == nil, let draft = TodoDraft.parse("todo " + TodoIntent.task(in: query)) {
                    ranked.append((TodoIntent.isLikely(query) ? 915 : 300, CommandItem(id: "keep-todo", title: draft.title,
                                                    subtitle: draft.when == .someday ? "New to-do, someday" : "New to-do for \(TodoDraft.phrase(draft.when, draft.time))",
                                                    kind: "To-do", icon: .glyph(.todo), action: .addTodo(draft.title, draft.when, draft.time))))
                }
            }
        }

        // A host that starts with what you typed beats the search, like an address bar autocomplete.
        func score(title: String, host: String, base: Int) -> Int? {
            let title = title.lowercased(), host = host.lowercased()
            if host.hasPrefix(needle) { return base + 200 }
            if title.hasPrefix(needle) { return base + 120 }
            if host.contains(needle) || title.contains(needle) { return base }
            return nil
        }

        // Sites already offered, so a popular site doesn't repeat one of your own.
        var offeredHosts = Set(literalURL.map { [$0.displayHost] } ?? [])

        // Typing for a private tab, a normal tab isn't offered: Return would
        // switch to it and leave private browsing.
        // Sites whose address starts with what's typed, front page first (below).
        var sites: [String: (url: URL, title: String?, visits: Int)] = [:]
        func noteSite(_ url: URL, title: String?, visits: Int) -> Bool {
            let host = url.displayHost
            guard needle.count >= 2, host.lowercased().hasPrefix(needle) else { return false }
            var site = sites[host] ?? (URL(string: "\(url.scheme ?? "https")://\(url.host() ?? host)/") ?? url, nil, 0)
            site.visits += visits
            if url.path.count <= 1, let title { site.title = title }
            sites[host] = site
            return true
        }
        var tabPages = Set<String>()
        for tab in browser.tabs where tab.id != browser.selectedID
            && (browser.commandMode != .privateTab || tab.isPrivate) {
            // One row per page, however many tabs have it open.
            guard tabPages.insert(tab.url?.absoluteString ?? tab.id.uuidString).inserted else { continue }
            let onSite = tab.url.map { noteSite($0, title: tab.displayTitle, visits: 1) } ?? false
            // An article open in a tab comes after its site, as in history.
            let base = onSite && (tab.url?.path.count ?? 0) > 1 ? 560 : 760
            if let value = score(title: tab.displayTitle, host: onSite && base == 560 ? "" : tab.url?.displayHost ?? "", base: base)
                ?? (onSite ? base : nil) {
                ranked.append((value, tabItem(tab)))
            }
        }
        for pin in pins {
            if let value = score(title: pin.title, host: pin.host, base: 740) {
                ranked.append((value, pinItem(pin)))
                offeredHosts.insert(pin.host)
            }
        }
        // A page already open in a tab isn't repeated from history, even when the
        // address differs slightly (index.hr vs index.hr/mobile).
        let openPages = Set(browser.tabs.compactMap { tab in tab.url.map { "\($0.displayHost)|\(tab.displayTitle)" } })
        let openURLs = Set(browser.tabs.compactMap { $0.url?.absoluteString })
        // A site whose address starts with what you typed: the site itself (its
        // front page) is the best guess, ahead of searching for the letters and
        // ahead of any one article on it, however often that was read.
        var articles: [(entry: HistoryEntry, url: URL)] = []
        for entry in browser.history(matching: query, limit: 16) where !openURLs.contains(entry.url) {
            guard let url = URL(string: entry.url) else { continue }
            let host = url.displayHost
            if noteSite(url, title: entry.title, visits: entry.visitCount), url.path.count <= 1 { continue }
            if openPages.contains("\(host)|\(entry.title.isEmpty ? host : entry.title)") { continue }
            articles.append((entry, url))
        }
        for (host, site) in sites where !offeredHosts.contains(host) {
            // Its front page open in a tab: that tab is the row instead.
            if browser.tabs.contains(where: { $0.url?.displayHost == host && ($0.url?.path.count ?? 0) <= 1 }) {
                if let index = ranked.firstIndex(where: { if case .switchTab(let tab) = $0.item.action { return tab.url?.displayHost == host && (tab.url?.path.count ?? 0) <= 1 } else { return false } }) {
                    ranked[index].score = 960
                }
                continue
            }
            ranked.append((910 + min(site.visits, 40), CommandItem(
                id: "site-\(host)", title: site.title.flatMap { $0.isEmpty ? nil : $0 } ?? host,
                subtitle: host, kind: "Open", icon: .site(host), action: .open(site.url))))
            offeredHosts.insert(host)
        }
        // Articles and sub-pages: under the site and the search, unless their
        // own title is what's being typed.
        for (entry, url) in articles.prefix(8) {
            let value = score(title: entry.title, host: sites[url.displayHost] == nil ? url.displayHost : "", base: 600) ?? 560
            ranked.append((value + min(entry.visitCount, 20), CommandItem(
                id: "history-\(entry.url)", title: entry.title.isEmpty ? url.displayHost : entry.title,
                subtitle: url.displayHost, kind: "History", icon: .site(url.displayHost), action: .open(url))))
            offeredHosts.insert(url.displayHost)
        }

        // Well-known sites, for addresses you haven't visited yet. From three
        // letters the best one beats a search, like address-bar autocomplete.
        if needle.count >= 2, !needle.contains(" ") {
            for (offset, site) in PopularSites.matching(needle).enumerated() where !offeredHosts.contains(site.host) {
                guard let url = URL(string: "https://\(site.host)") else { continue }
                // "index.hr/oglasi" wears index.hr's icon.
                let iconHost = String(site.host.prefix { $0 != "/" })
                ranked.append(((needle.count >= 3 ? 905 : 870) - offset, CommandItem(
                    id: "popular-\(site.host)", title: site.name, subtitle: site.host,
                    kind: "Open", icon: .site(iconHost), action: .open(url))))
            }
        }

        // "weather", "vrijeme": now, where Today's weather is for; Return opens Today.
        let weatherWords = ["weather", "forecast", "vrijeme", "vreme", "prognoza"]
        if needle.count >= 3, weatherWords.contains(where: { $0.hasPrefix(needle) }) {
            let item: CommandItem
            if let weather = TodayModel.shared.weather {
                item = CommandItem(id: "weather", title: "\(Int(weather.temperature.rounded()))° " + weather.condition
                                       + (weather.place.map { " in \($0)" } ?? ""),
                                   subtitle: weather.dayLine,
                                   kind: "Today", icon: .image("phosphor/\(weather.glyph)"), action: .today)
            } else {
                item = CommandItem(id: "weather", title: "Weather", subtitle: "In Today", kind: "Today",
                                   icon: .glyph(.today), action: .today)
            }
            ranked.append((weatherWords.contains(needle) ? 1012 : 890, item))
        }

        // "calendar", "next": what's next on your calendar; Return opens Calendar there.
        let calendarWords = ["calendar", "kalendar", "next meeting", "agenda", "sljedeće", "sljedece", "raspored"]
        if needle.count >= 3, calendarWords.contains(where: { $0.hasPrefix(needle) }) || needle == "next" {
            let item = calendarItem()
            ranked.append((calendarWords.contains(needle) || needle == "next" ? 1012 : 890, item))
        }

        let actions: [(words: [String], item: CommandItem)] = [
            (["summarize", "summary", "tldr"], CommandItem(id: "action-summarize", title: "Summarize this page", subtitle: "",
                                                          kind: "Action", icon: .glyph(.summarize), action: .summarize)),
            (["find", "search page"], CommandItem(id: "action-find", title: "Find on page", subtitle: "",
                                                  kind: "Action", icon: .glyph(.search), action: .findOnPage)),
            (["settings", "preferences", "api key"], CommandItem(id: "action-settings", title: "Settings", subtitle: "",
                                                                 kind: "Action", icon: .glyph(.settings), action: .settings)),
            (["to-do", "todo", "todos", "to do", "tasks"], CommandItem(id: "action-todos", title: "To-do", subtitle: "Type \u{201C}todo\u{201D} and a task to add one",
                                                                       kind: "Action", icon: .glyph(.todo), action: .todos)),
            (["today", "danas"], CommandItem(id: "action-today", title: "Today", subtitle: "Weather, calendar, to-dos, news",
                                             kind: "Action", icon: .glyph(.today), action: .today)),
        ]
        for (words, item) in actions where words.contains(where: { $0.hasPrefix(needle) }) {
            let needsPage = ["action-summarize", "action-find"].contains(item.id)
            if needsPage && browser.selectedTab == nil { continue }
            // Typed in full, a place in roko (Settings, To-do) is what's meant,
            // not a web search for the word: it goes first, and Return opens it.
            let isPlace = ["action-settings", "action-todos", "action-today"].contains(item.id)
            let exact = words.contains(needle)
            // Above the calculator too: "today" opens Today rather than showing the date.
            ranked.append((isPlace && exact ? 1010 : needle.count >= 3 ? 880 : 500, item))
        }

        // The engine often suggests exactly what was typed (give or take a
        // space or a capital); the Search row already covers that.
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let typed = folded(query)
        for (offset, suggestion) in suggestions.enumerated() where folded(suggestion) != typed {
            ranked.append((400 - offset, CommandItem(id: "suggest-\(suggestion)", title: suggestion, subtitle: "",
                                                     kind: "", icon: .glyph(.search), action: .search(suggestion))))
        }

        // A site's name ("sportske novosti", "jutarnji", "glas slavonije"): the
        // site itself first, ahead of a search for the name. Found among your
        // tabs, pins and history whose title starts with what was typed, and
        // the one nearest the site's front page wins (its title is the site's
        // name, its address the shortest).
        if needle.count >= 4, !ResearchDepth.prefersAnswer(query), !TodoIntent.isLikely(query),
           let site = Self.siteNamed(needle, in: ranked.map(\.item)),
           let index = ranked.firstIndex(where: { $0.item.id == site.id }) {
            ranked[index].score = max(ranked[index].score, 940)
        }

        var seen = Set<String>()
        return ranked
            .sorted { $0.score > $1.score }
            .map(\.item)
            .filter { seen.insert($0.id).inserted }
            .prefix(12)
            .map { $0 }
    }

    private static func pinItem(_ pin: Pin) -> CommandItem {
        CommandItem(id: "pin-\(pin.url)", title: pin.title.isEmpty ? pin.host : pin.title,
                    subtitle: pin.host, kind: "Pinned", icon: .site(pin.host), action: .openPin(pin))
    }

    private static func tabItem(_ tab: BrowserTab) -> CommandItem {
        let host = tab.url?.displayHost ?? ""
        return CommandItem(id: "tab-\(tab.id)", title: tab.displayTitle, subtitle: host,
                           kind: "Already open", icon: .site(host), action: .switchTab(tab))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A weather question about a place: "weather in London", "london weather",
/// "vrijeme u Zagrebu", "prognoza Split". Not one about a day ("vrijeme sutra").
nonisolated enum WeatherQuery {
    private static let words = ["weather", "forecast", "vrijeme", "vrijme", "vreme", "prognoza"]
    private static let notPlaces: Set<String> = ["today", "tomorrow", "now", "weekend", "danas", "sutra", "sada",
                                                 "vikend", "prekosutra", "this week", "ovaj tjedan"]

    static func place(in query: String) -> String? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        var rest: [String]
        if Self.words.contains(words[0]) {
            rest = Array(words.dropFirst())
            if let first = rest.first, ["in", "u", "za", "for", "at"].contains(first) { rest.removeFirst() }
        } else if let last = words.last, Self.words.contains(last) {
            rest = Array(words.dropLast())
        } else {
            return nil
        }
        let place = rest.joined(separator: " ")
        guard place.count >= 2, !notPlaces.contains(place) else { return nil }
        return place
    }

    /// Croatian number-plate codes, as people write towns for short.
    private static let plates = ["zg": "Zagreb", "st": "Split", "os": "Osijek", "ri": "Rijeka", "zd": "Zadar",
                                 "pu": "Pula", "du": "Dubrovnik", "vž": "Varaždin", "vz": "Varaždin", "sb": "Slavonski Brod",
                                 "ka": "Karlovac", "si": "Šibenik", "vk": "Vinkovci", "vu": "Vukovar", "đa": "Đakovo",
                                 "da": "Đakovo", "ko": "Koprivnica", "čk": "Čakovec", "ck": "Čakovec", "bj": "Bjelovar"]

    /// What to look the place up as, in order: a plate code's town, the words
    /// as typed, then as the town would be named ("u Zagrebu" is Zagreb,
    /// "u Rijeci" Rijeka, "u Puli" Pula, "u Zadru" Zadar).
    static func lookups(for place: String) -> [String] {
        if let town = plates[place] { return [town] }
        var names = [place]
        if place.hasSuffix("dru") { names.append(String(place.dropLast(3)) + "dar") }
        if place.hasSuffix("ci") { names.append(String(place.dropLast(2)) + "ka") }
        if place.hasSuffix("u") { names.append(String(place.dropLast())) }
        if place.hasSuffix("i") { names.append(String(place.dropLast()) + "a") }
        if place.hasSuffix("ju") { names.append(String(place.dropLast(2)) + "ja") }
        return names
    }
}

/// Answers kept with your pins (the weather, "days until 24.12.", "100 eur
/// in usd"), as what was typed: worked out again whenever the bar opens.
@MainActor
enum PinnedAnswers {
    private static let key = "pinnedAnswers"
    /// The pinned towns' weather as last fetched, shown at once next time.
    static var lastWeather: [String: TodayWeather] {
        get {
            UserDefaults.standard.data(forKey: "pinnedAnswers.weather")
                .flatMap { try? JSONDecoder().decode([String: TodayWeather].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "pinnedAnswers.weather") }
    }

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ query: String) {
        guard !query.isEmpty, !all.contains(query) else { return }
        UserDefaults.standard.set(all + [query], forKey: key)
    }

    static func remove(_ query: String) {
        UserDefaults.standard.set(all.filter { $0 != query }, forKey: key)
    }
}

extension WeatherQuery {
    /// The weather for a town asked about by name, or nil when no town is found.
    static func weather(for query: String) async -> TodayWeather? {
        guard let place = place(in: query) else { return nil }
        var found: WeatherPlace?
        for name in lookups(for: place) where found == nil {
            // A town of that exact name first: "Zagrebu" alone may find a village, "Zagreb" the city.
            let results = await WeatherPlace.search(name)
            found = results.first { $0.name.lowercased() == name.lowercased() } ?? (name == place ? nil : results.first)
        }
        if found == nil { found = await WeatherPlace.search(place).first }
        guard let found else { return nil }
        return try? await TodayWeather.fetch(at: found.coordinate, place: found.name)
    }
}

/// Whether what's typed reads like something to do rather than something to
/// look up: it starts with a doing word ("call", "buy", "pay", "nazvati",
/// "kupiti"), says "remind me to" or "don't forget", or ends on a day or a
/// time with words before it ("Ana's birthday tomorrow", "dentist at 15").
/// A question ("how to pay rent") is never one.
nonisolated enum TodoIntent {
    private static let starts: [String] = [
        // English
        "call", "phone", "ring", "text", "email", "e-mail", "mail", "message", "reply", "send", "buy", "get", "pick up",
        "pay", "book", "order", "renew", "cancel", "return", "fix", "clean", "wash", "finish", "submit", "prepare", "write",
        "bring", "schedule", "follow up", "remind",
        "don't forget", "dont forget", "remember to", "remind me", "need to", "have to", "todo", "to do",
        // Croatian (infinitives, and the "I must / don't forget" ways in)
        "nazvati", "nazovi", "zvati", "poslati", "pošalji", "posalji", "kupiti", "kupi", "platiti", "plati", "napisati",
        "napiši", "odgovoriti", "odgovori", "rezervirati", "naručiti", "naruci", "naruči", "otkazati", "vratiti", "popraviti",
        "očistiti", "ocistiti", "oprati", "završiti", "zavrsiti", "predati", "pripremiti",
        "donijeti", "podsjeti", "ne zaboravi", "moram", "treba",
    ]
    private static let questions = ["how", "what", "why", "where", "when", "who", "which", "is ", "are ", "can ", "does ",
                                    "do ", "kako", "što", "sto", "zašto", "zasto", "gdje", "kada", "tko", "koji", "je li"]
    private static let lookups = ["weather", "forecast", "vrijeme", "vrijme", "vreme", "prognoza", "calendar", "kalendar",
                                  "news", "vijesti", "score", "rezultat", "flights", "letovi", "rate", "tečaj", "tecaj"]
    private static let leadIns = ["remind me to ", "remind me ", "don't forget to ", "dont forget to ", "don't forget ",
                                  "remember to ", "need to ", "have to ", "podsjeti me da ", "podsjeti me ", "ne zaboravi ",
                                  "moram ", "treba "]

    static func isLikely(_ query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.contains(" "), !lower.hasSuffix("?"),
              !questions.contains(where: { lower.hasPrefix($0) }),
              // "weather tomorrow", "calendar friday": looked up, not done.
              WeatherQuery.place(in: lower) == nil,
              !lookups.contains(where: { lower.hasPrefix($0 + " ") }) else { return false }
        if starts.contains(where: { lower.hasPrefix($0 + " ") }) { return true }
        // Words, then a day or a time: what it's for and when.
        if let read = TodoDraft.read(query), !read.title.isEmpty, read.when != nil || read.time != nil { return true }
        return false
    }

    /// The task itself, without "remind me to" and its kin.
    static func task(in query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard let lead = leadIns.first(where: { lower.hasPrefix($0) }) else { return trimmed }
        return String(trimmed.dropFirst(lead.count))
    }
}

/// Swipe a row left to forget it: it follows the finger with a trash mark
/// coming in behind, and past a third of the way, let go and it's gone.
/// A mostly vertical drag is left to the list, which scrolls.
private struct SwipeToForget: ViewModifier {
    let enabled: Bool
    /// Called while a row is being swiped, so its tap doesn't also fire.
    let swiping: () -> Void
    let forget: () -> Void
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .trailing) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.trailing, 20)
                        .opacity(min(1, -offset / 80))
                }
                .simultaneousGesture(DragGesture(minimumDistance: 24).onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    offset = min(0, value.translation.width)
                    swiping()
                }.onEnded { value in
                    if offset < 0 { swiping() }
                    if value.translation.width < -120 {
                        withAnimation(.easeIn(duration: 0.18)) { offset = -500 } completion: { forget(); offset = 0 }
                    } else {
                        withAnimation(.snappy(duration: 0.25)) { offset = 0 }
                    }
                })
                .sensoryFeedback(.impact(weight: .light), trigger: offset < -120)
        } else {
            content
        }
    }
}

/// "parking", "parkiranje", "platiti parking": asking to pay for parking.
nonisolated enum ParkingQuery {
    private static let words = ["parking", "parkiranje", "parkiraj", "parkirati", "parkiralište", "plati parking",
                                "platiti parking", "pay parking", "pay for parking"]

    static func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        // From "parki" on: "park" alone is as likely a park, and this asks where you are.
        return needle.count >= 5 && words.contains { $0.hasPrefix(needle) || needle == $0 }
    }
}
