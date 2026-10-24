import SwiftData
import SwiftUI

struct CommandItem: Identifiable {
    enum Action {
        case open(URL), switchTab(BrowserTab), openPin(Pin), search(String),
             browse(String), summarize, findOnPage, privateTab, settings, copy(String),
             pasteLink, openCopied(URL), todos, today, addTodo(String, TodoWhen)
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let icon: Icon
    let action: Action

    enum Icon {
        case glyph(Glyph.Kind), site(String)
    }
}

/// One field, one ranked list: addresses, searches, pins, open tabs, history,
/// suggestions and page actions. The best match sits right above the field,
/// where the thumb is, and Return runs it.
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
    @State private var selection = 0
    @State private var resultsHeight: CGFloat = 0
    @State private var hasCopiedLink = false
    /// The copied link itself, when roko may read it (see CopiedLink.peek).
    @State private var copiedURL: URL?
    /// Mid-blink of the private switch's eye.
    @State private var blink = false
    @FocusState private var focused: Bool

    /// Panel corner, and the row inset inside it. Rows round by the difference,
    /// so the two curves run parallel instead of a tight corner in a loose one.
    static let corner: CGFloat = 28
    static let inset: CGFloat = 8

    var body: some View {
        ZStack(alignment: .bottom) {
            // Nothing laid over the page: the panel is the only thing that
            // opens, riding up with the keyboard in one move. A full-screen
            // veil fading in on top made opening feel like two steps.
            // A tap anywhere above the panel closes it.
            Color.clear
                .contentShape(.rect)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                results
                // Typing "todo" brings today's to-dos up under the To-do row,
                // to tick off there; otherwise the bar stays for searching.
                if items.first?.id == "action-todos" && !dueTodos.isEmpty { todoWidget }
                if query.isEmpty && (!pins.isEmpty || todos.contains(where: \.isDueNow)) { pinRow }
                field
            }
            .foregroundStyle(Theme.ink)
            .background(Theme.panel, in: .rect(cornerRadius: CommandBarView.corner))
            .overlay(RoundedRectangle(cornerRadius: CommandBarView.corner).strokeBorder(Theme.edge))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.height > 60 { dismiss() }
            })
        }
        .onAppear {
            query = browser.commandPrefill
            rebuild()
            focused = true
        }
        .task {
            guard await CopiedLink.isWaiting() else { return }
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
        }
        .onChange(of: CurrencyRates.shared.date) { rebuild() }
        .task(id: query) {
            // A short pause so suggestions aren't requested for every keystroke.
            let text = query.trimmingCharacters(in: .whitespaces)
            guard UserDefaults.standard.object(forKey: "suggestions") as? Bool ?? true,
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
        ScrollView {
            LazyVStack(spacing: 2) {
                // Best match last, so it lands next to the field.
                ForEach(Array(items.enumerated()).reversed(), id: \.element.id) { index, item in
                    if case .pasteLink = item.action {
                        copiedLinkRow
                    } else {
                        Button { perform(item) } label: {
                            CommandRow(item: item, isSelected: index == selection && !query.isEmpty)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        // Hug the rows; scroll only past a comfortable height.
        .frame(height: items.isEmpty ? 0 : min(resultsHeight, 380))
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
        todos.filter { $0.isDueNow || justDone.contains($0.persistentModelID) }
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
                    Spacer(minLength: 0)
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

    /// Your pins, one tap away, right above the field where the thumb already
    /// is: just their icons, on the same axis as the icons in the list. A long
    /// press says which page it is.
    private var pinRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // Today's to-dos first while any are left: the icon and how many.
                TodoPin(size: 28) { icon in
                    icon.frame(width: 52, height: 48).contentShape(.rect)
                }
                ForEach(pins) { pin in
                    let name = pin.title.isEmpty ? pin.host : pin.title
                    Button { focused = false; browser.open(pin) } label: {
                        SiteIcon(host: pin.host, size: 28)
                            .frame(width: 52, height: 48)
                            .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel(name)
                    .contextMenu {
                        Section(name) {
                            Button("Unpin", role: .destructive) { browser.unpin(pin) }
                        }
                    }
                }
            }
            // The first icon centred where the field's and the rows' icons are.
            .padding(.horizontal, 5)
        }
        .scrollIndicators(.hidden)
        .padding(.top, items.isEmpty ? 6 : 0)
    }

    private var field: some View {
        HStack(spacing: 12) {
            // While typing hides the switch, the leading mark keeps private mode visible.
            let showsPrivate = browser.commandMode == .privateTab && !query.isEmpty
            Glyph(showsPrivate ? .eyeClosed : .search, size: 18)
                .foregroundStyle(showsPrivate ? Theme.accent : Theme.secondaryInk)
                .frame(width: 22)
            TextField(placeholder, text: $query)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                // Autocorrect turns "theverge.com" into "the verge.com", a search.
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
                          let item = items[safe: selection] else { return }
                    perform(item)
                }
                .onKeyPress(.upArrow) { move(1) }
                .onKeyPress(.downArrow) { move(-1) }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !query.isEmpty {
                Button { query = "" } label: {
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
                privateSwitch
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
        // The rows' inset plus their padding: icons share one axis down the panel.
        .padding(.horizontal, Self.inset + 12)
        .frame(height: 56)
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
        switch browser.commandMode {
        case .privateTab: "Private search or address"
        case .currentTab, .newTab: "Search or enter address"
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        selection = min(max(selection + step, 0), items.count - 1)
        return .handled
    }

    private func dismiss() {
        focused = false
        browser.panel = .none
    }

    // MARK: Ranking

    private func rebuild() {
        items = CommandRanker.rank(query: query, browser: browser, suggestions: suggestions)
        // Nothing typed yet: a link copied a moment ago, here or on a Mac.
        // Above the pins, so they keep one place right over the field.
        if query.isEmpty, hasCopiedLink {
            items = [copiedURL.map {
                CommandItem(id: "copied-link", title: $0.shortDisplay, subtitle: "Link you copied",
                            kind: "", icon: .site($0.displayHost), action: .openCopied($0))
            } ?? CommandItem(id: "copied-link", title: "Link you copied", subtitle: "",
                             kind: "", icon: .glyph(.link), action: .pasteLink)]
        }
        // Resolve where Return would go before it's pressed.
        switch items.first?.action {
        case .open(let url): DNSPrefetcher.warm(url.host())
        case .openPin(let pin): DNSPrefetcher.warm(URL(string: pin.url)?.host())
        case .search(let text): DNSPrefetcher.warm(SearchEngine.current.searchURL(for: text).host())
        default: break
        }
    }

    private func perform(_ item: CommandItem) {
        focused = false
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
        case .addTodo(let title, let when):
            context.insert(Todo(title: title, when: when))
            try? context.save()
            browser.panel = .none
            browser.showToast(when == .today ? "Added to today's to-dos" : "To-do added for \(TodoDraft.label(when).lowercased())")
        case .copy(let result):
            UIPasteboard.general.string = result
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

private struct CommandRow: View {
    let item: CommandItem
    let isSelected: Bool

    private var isAnswer: Bool {
        if case .copy = item.action { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch item.icon {
                case .glyph(let kind): Glyph(kind, size: 18).foregroundStyle(Theme.secondaryInk)
                case .site(let host): SiteIcon(host: host, size: 18)
                }
            }
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
            Text(item.kind)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faintInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Theme.selection : .clear,
                    in: .rect(cornerRadius: CommandBarView.corner - CommandBarView.inset))
        .contentShape(.rect)
    }
}

enum CommandRanker {
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
                                             kind: TodoDraft.label(draft.when), icon: .glyph(.todo),
                                             action: .addTodo(draft.title, draft.when))))
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
                if TodoDraft.parse(query) == nil, let draft = TodoDraft.parse("todo " + query) {
                    ranked.append((845, CommandItem(id: "keep-todo", title: "Add to-do",
                                                    subtitle: draft.when == .someday ? "Someday" : "For \(TodoDraft.label(draft.when).lowercased())",
                                                    kind: "To-do", icon: .glyph(.todo), action: .addTodo(draft.title, draft.when))))
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
        for tab in browser.tabs where tab.id != browser.selectedID
            && (browser.commandMode != .privateTab || tab.isPrivate) {
            if let value = score(title: tab.displayTitle, host: tab.url?.displayHost ?? "", base: 760) {
                ranked.append((value, tabItem(tab)))
                offeredHosts.insert(tab.url?.displayHost ?? "")
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
        for entry in browser.history(matching: query, limit: 8) where !openURLs.contains(entry.url) {
            guard let url = URL(string: entry.url) else { continue }
            if openPages.contains("\(url.displayHost)|\(entry.title.isEmpty ? url.displayHost : entry.title)") { continue }
            // A site you've been to whose address starts with what you typed is
            // the best guess of all, ahead of searching for the letters.
            let value = url.displayHost.lowercased().hasPrefix(needle) && needle.count >= 2
                ? 910 : score(title: entry.title, host: url.displayHost, base: 600) ?? 560
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
