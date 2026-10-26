import SwiftData
import SwiftUI

/// The shopping list, in the order a shop is walked: each thing in its aisle,
/// Croatian or English. Tap the circle as it goes in the basket, tap its words
/// to change them, long-press to put it in another aisle (roko remembers) or
/// delete it. Under the list, what you often buy and haven't added; as you
/// type, what you've bought before. Pull down past the top to close it.
struct ShoppingView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \ShoppingItem.createdAt) private var items: [ShoppingItem]
    @Query private var habits: [ShoppingHabit]
    /// In the basket a moment ago: still in its aisle, struck through, so a slip can be undone.
    @State private var justDone: Set<PersistentIdentifier> = []
    @State private var editing: PersistentIdentifier?
    @State private var adding = false
    @State private var draft = ""
    @State private var showsBought = false
    /// Listening for a list said aloud; what's heard so far.
    @State private var listening = false
    @State private var heard = ""
    @State private var listenTask: Task<Void, Never>?
    @Namespace private var barSpace
    /// Read so the list speaks a newly chosen language at once.
    @AppStorage(ListLanguage.key) private var language = ListLanguage.automatic.rawValue
    /// The shop whose list is showing: groceries, the drugstore, the pharmacy.
    @AppStorage(Shop.key) private var shopName = Shop.grocery.rawValue

    private var shop: Shop { Shop(rawValue: shopName) ?? .grocery }

    private var toBuy: [ShoppingItem] {
        items.filter { $0.shop == shop && (!$0.done || justDone.contains($0.persistentModelID)) }
    }

    /// On the list and not yet bought, by how it's known.
    private var listed: Set<String> {
        Set(items.filter { !$0.done }.map(\.key))
    }

    private var aisles: [(Aisle, [ShoppingItem])] {
        let grouped = Dictionary(grouping: toBuy, by: \.aisle)
        return Aisle.allCases.compactMap { aisle in
            guard let items = grouped[aisle], !items.isEmpty else { return nil }
            return (aisle, items.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) })
        }
    }

    private var bought: [ShoppingItem] {
        items.filter { $0.shop == shop && $0.done && !justDone.contains($0.persistentModelID) }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    private var suggested: [ShoppingHabit] {
        Shopping.suggestions(habits, excluding: listed, in: shop)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                shops
                    .padding(.bottom, 26)
                if aisles.isEmpty {
                    Text(ListLanguage.say("Nothing to buy here. Add something below.", "Ovdje nema ništa za kupiti. Dodaj nešto ispod."))
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.top, 40)
                        .padding(.bottom, 50)
                        .frame(maxWidth: .infinity)
                }
                ForEach(aisles, id: \.0) { aisle, items in
                    aisleView(aisle, items)
                        .padding(.bottom, 30)
                }
                if !suggested.isEmpty { suggestions }
                if !bought.isEmpty { boughtSection }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .animation(.snappy(duration: 0.3), value: items.map(\.persistentModelID))
            .animation(.snappy(duration: 0.3), value: items.map(\.aisleName))
            .animation(.snappy(duration: 0.3), value: justDone)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .onAppear { Shopping.tidy(in: context) }
        // Ready before the first letter: read off the main thread.
        .task { await Task.detached(priority: .utility) { _ = ShoppingCatalogue.shared }.value }
        // Pull down past the top to close, as To-do does.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulled in
            if pulled { close() }
        }
    }

    // MARK: Shops

    /// Each shop's list, a tap apart: the one showing in ink, each with how
    /// many things are left on it.
    private var shops: some View {
        HStack(spacing: 22) {
            ForEach(Shop.allCases) { each in
                let left = items.filter { !$0.done && $0.shop == each }.count
                Button {
                    withAnimation(.snappy(duration: 0.25)) { shopName = each.rawValue }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(each.title)
                            .font(.system(size: 17, weight: each == shop ? .semibold : .regular))
                        if left > 0 {
                            Text("\(left)")
                                .font(.system(size: 15).monospacedDigit())
                        }
                    }
                    .foregroundStyle(each == shop ? Theme.ink : Theme.secondaryInk)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(each.title + (left > 0 ? ", \(left)" : ""))
                .accessibilityAddTraits(each == shop ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .sensoryFeedback(.selection, trigger: shopName)
    }

    // MARK: Aisles

    private func aisleView(_ aisle: Aisle, _ items: [ShoppingItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(aisle.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 8)
            ForEach(items) { item in
                row(item)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    private func row(_ item: ShoppingItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button { toggle(item) } label: {
                TodoCircle(done: item.done)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            .accessibilityLabel(item.done ? ListLanguage.say("In the basket", "U košarici") : ListLanguage.say("Not bought", "Nije kupljeno"))
            .padding(.leading, -11)

            if editing == item.persistentModelID {
                ItemEditor(item: item) { finished in
                    editing = nil
                    if finished.trimmingCharacters(in: .whitespaces).isEmpty {
                        delete(item)
                    } else {
                        // Its words changed, so may its aisle, unless you chose it.
                        withAnimation(.snappy) { item.aisle = Shopping.aisle(for: item.title, in: context) }
                        save()
                        Shopping.guessAisle(for: item, in: context)
                    }
                }
            } else {
                Text(item.title)
                    .font(.system(size: 17))
                    .foregroundStyle(item.done ? Theme.secondaryInk : Theme.ink)
                    .strikethrough(item.done, color: Theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { if !item.done { editing = item.persistentModelID } }
            }
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .contextMenu { menu(for: item) }
    }

    @ViewBuilder
    private func menu(for item: ShoppingItem) -> some View {
        Menu {
            ForEach(Aisle.allCases) { aisle in
                Button {
                    withAnimation(.snappy) { Shopping.move(item, to: aisle, in: context) }
                } label: {
                    if aisle == item.aisle { Label(aisle.title, systemImage: "checkmark") } else { Text(aisle.title) }
                }
            }
        } label: {
            Label(ListLanguage.say("Move to Aisle", "Premjesti u odjel"), systemImage: "arrow.turn.down.right")
        }
        Menu {
            ForEach(Shop.allCases.filter { $0 != item.shop }) { other in
                Button(other.title) {
                    withAnimation(.snappy) { Shopping.move(item, to: other, in: context) }
                }
            }
        } label: {
            Label(ListLanguage.say("Move to Shop", "Premjesti u trgovinu"), systemImage: "storefront")
        }
        Divider()
        Button(role: .destructive) { delete(item) } label: { Label(ListLanguage.say("Delete", "Obriši"), systemImage: "trash") }
    }

    // MARK: Suggestions

    /// What you often buy that isn't on the list, the ones due again first:
    /// a tap puts it on.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ListLanguage.say("You often buy", "Često kupuješ"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 8)
            ForEach(suggested) { habit in
                Button { add(habit.title) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Glyph(.plus, size: 15, weight: 2)
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(width: 44, height: 44)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                            .padding(.leading, -11)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(habit.title)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.ink)
                            if let gap = habit.usualGap {
                                Text(Self.every(gap))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ListLanguage.say("Add ", "Dodaj ") + habit.title)
                .transition(.opacity)
            }
        }
        .padding(.bottom, 30)
    }

    /// "Usually every week", from the days between buying it.
    static func every(_ days: Double) -> String {
        let n = Int(days.rounded())
        return switch days {
        case ..<1.5: ListLanguage.say("Usually every day", "Obično svaki dan")
        case ..<5.5: ListLanguage.say("Usually every \(n) days", n < 5 ? "Obično svaka \(n) dana" : "Obično svakih \(n) dana")
        case ..<10: ListLanguage.say("Usually every week", "Obično svaki tjedan")
        case ..<18: ListLanguage.say("Usually every two weeks", "Obično svaka dva tjedna")
        case ..<45: ListLanguage.say("Usually every month", "Obično svaki mjesec")
        default: ListLanguage.say("Now and then", "Povremeno")
        }
    }

    /// "3 things to buy", "Za kupiti: 3 stvari"; "Shopping" when there's nothing.
    static func toBuy(_ count: Int) -> String {
        switch (count, ListLanguage.current) {
        case (0, .english): "Shopping"
        case (0, .croatian): "Kupovina"
        case (1, .english): "One thing to buy"
        case (_, .english): "\(count) things to buy"
        case (_, .croatian): count % 10 == 1 && count % 100 != 11 ? "\(count) stvar za kupiti" : "\(count) stvari za kupiti"
        }
    }

    // MARK: Bought

    /// In the basket, folded under its count; opened, each a tap from back on
    /// the list, and Clear to let them all go.
    private var boughtSection: some View {
        let done = bought
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { showsBought.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(ListLanguage.say("Bought", "Kupljeno"))
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(done.count)")
                            .font(.system(size: 15).monospacedDigit())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(showsBought ? 90 : 0))
                    }
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(minHeight: 36)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsBought ? ListLanguage.say("Hide bought", "Sakrij kupljeno") : ListLanguage.say("Show bought", "Prikaži kupljeno"))
                Spacer()
                if showsBought {
                    Button(ListLanguage.say("Clear", "Očisti")) {
                        withAnimation(.snappy) { done.forEach(context.delete) }
                        save()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(minHeight: 36)
                    .transition(.opacity)
                }
            }
            if showsBought {
                ForEach(done.prefix(40)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Button { toggle(item) } label: {
                            TodoCircle(done: true)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        .accessibilityLabel(ListLanguage.say("Bought. Tap to put it back on the list", "Kupljeno. Dodirni za vraćanje na popis"))
                        .padding(.leading, -11)
                        Text(item.title)
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.secondaryInk)
                            .strikethrough(true, color: Theme.secondaryInk)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .contextMenu {
                        Button(role: .destructive) { delete(item) } label: { Label(ListLanguage.say("Delete", "Obriši"), systemImage: "trash") }
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .padding(.bottom, 30)
    }

    // MARK: Bar

    /// The app's bar, for Shopping. Its capsule widens into a field in place;
    /// "milk, eggs and bread" is three things, each to its aisle as Return
    /// adds them. Above the field, what you've bought before that starts so.
    @ViewBuilder
    private var bar: some View {
        if listening {
            // What's heard, as it's heard; done after a pause, or with a tap.
            HStack(spacing: 12) {
                Glyph(.microphone, size: 18)
                    .foregroundStyle(Theme.accent)
                Text(heard.isEmpty ? ListLanguage.say("Say what to buy", "Reci što kupiti") : heard)
                    .font(.system(size: 17))
                    .foregroundStyle(heard.isEmpty ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                Button(ListLanguage.say("Done", "Gotovo")) { finishListening() }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44)
            }
            .padding(.leading, 22)
            .padding(.trailing, 18)
            .frame(minHeight: Theme.barHeight + 8)
            .background { Capsule().fill(Theme.raised) }
            .barSurface(cornerRadius: Theme.barRadius)
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 4)
            .background(alignment: .top) { FadeEdge(color: Theme.canvas, height: 40).offset(y: 12) }
            .transition(.opacity)
        } else if adding {
            VStack(spacing: 0) {
                let completions = Shopping.completions(for: draft, in: habits, excluding: listed)
                if !completions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(completions) { completion in
                            Button {
                                add(Shopping.finishing(draft, with: completion.title))
                                draft = ""
                            } label: {
                                HStack(spacing: 12) {
                                    Glyph(.plus, size: 13, weight: 2)
                                        .foregroundStyle(Theme.secondaryInk)
                                    Text(completion.title)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                        // The name, whole, before its aisle.
                                        .layoutPriority(1)
                                    Spacer(minLength: 8)
                                    // Its aisle when it fits whole; a clipped "Mlij…" says nothing.
                                    ViewThatFits {
                                        Text(completion.aisle.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.secondaryInk)
                                            .lineLimit(1)
                                            .fixedSize()
                                        Color.clear.frame(width: 0, height: 0)
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ListLanguage.say("Add ", "Dodaj ") + completion.title)
                        }
                    }
                    .padding(.horizontal, Theme.gutter + 18)
                    .padding(.bottom, 6)
                    .background(Theme.canvas)
                    .transition(.opacity)
                }
                HStack(spacing: 10) {
                    ReturnKeepingField(placeholder: ListLanguage.say("Milk, eggs, bread", "Mlijeko, jaja, kruh"), text: $draft, autocorrects: false) {
                        add(draft)
                        draft = ""
                    }
                    .frame(height: 44)
                    Button { finishAdding() } label: {
                        Glyph(.close, size: 13, weight: 2.2)
                            .frame(width: 30, height: 30)
                            .background(Theme.panel, in: .circle)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(GlyphButtonStyle())
                    .accessibilityLabel(ListLanguage.say("Done adding", "Gotovo"))
                }
                .padding(.leading, 22)
                .padding(.trailing, 8)
                .frame(height: Theme.barHeight + 8)
                .background {
                    Capsule().fill(Theme.raised)
                        .matchedGeometryEffect(id: "field", in: barSpace)
                }
                .barSurface(cornerRadius: Theme.barRadius)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 4)
            }
            .animation(.snappy(duration: 0.2), value: draft)
            .background(alignment: .top) { FadeEdge(color: Theme.canvas, height: 40).offset(y: 12) }
            .transition(.opacity)
        } else {
            ContextBar(leading: .init(glyph: .close, label: ListLanguage.say("Close", "Zatvori"), action: close),
                       glyph: .plus, title: ListLanguage.say("Add to list", "Dodaj na popis"),
                       launch: { withAnimation(.launcher) { adding = true } },
                       trailing: .init(glyph: .microphone, label: ListLanguage.say("Say a list", "Izgovori popis"), action: listen),
                       morphs: false, fieldSpace: barSpace)
                .transition(.opacity)
        }
    }

    // MARK: Listening

    /// Everyday things and what you've bought, for the recognizers to expect
    /// and for splitting what's said into things.
    private var known: [String] {
        habits.sorted { $0.count > $1.count }.map(\.title) + ShoppingCatalogue.shared.everyday
    }

    private func listen() {
        guard VoiceInput.isAuthorized else {
            Task {
                if !(await VoiceInput.authorize()) {
                    browser.showToast(ListLanguage.say("Allow the microphone and speech in Settings",
                                                       "Dopusti mikrofon i govor u Postavkama"))
                }
            }
            return
        }
        VoiceInput.expectedWords = known
        do { try VoiceInput.shared.start() } catch {
            VoiceInput.expectedWords = nil
            return
        }
        heard = ""
        withAnimation(.snappy(duration: 0.25)) { listening = true }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let voice = VoiceInput.shared
        listenTask = Task {
            // A list takes a breath between things: done after 2 seconds of quiet.
            while !Task.isCancelled, listening {
                try? await Task.sleep(for: .milliseconds(200))
                heard = voice.partial
                let now = Date.now
                if let last = voice.lastVoiceAt, !voice.partial.isEmpty, now.timeIntervalSince(last) > 2 { break }
                if voice.lastVoiceAt == nil, now.timeIntervalSince(voice.startedAt) > 8 { break }
            }
            if !Task.isCancelled { finishListening() }
        }
    }

    private func finishListening() {
        guard listening else { return }
        listenTask?.cancel()
        Task {
            let said = await VoiceInput.shared.stop() ?? heard
            VoiceInput.expectedWords = nil
            withAnimation(.snappy(duration: 0.25)) { listening = false }
            let things = Shopping.spokenItems(said, known: known)
            guard !things.isEmpty else {
                browser.showToast(ListLanguage.say("Didn't catch that", "Nisam čuo"))
                return
            }
            add(things.joined(separator: ", "))
        }
    }

    private func finishAdding() {
        withAnimation(.launcher) { adding = false }
        draft = ""
    }

    // MARK: Changes

    private func add(_ typed: String) {
        var result: (added: [ShoppingItem], already: [String]) = ([], [])
        withAnimation(.snappy) { result = Shopping.add(typed, in: context) }
        // Said when it isn't plain on screen: already there, or on another shop's list.
        if (result.added.isEmpty && !result.already.isEmpty) || result.added.contains(where: { $0.shop != shop }) {
            browser.showToast(Shopping.said(result, showing: shop))
        }
    }

    private func toggle(_ item: ShoppingItem) {
        let id = item.persistentModelID
        withAnimation(.snappy(duration: 0.25)) {
            item.done.toggle()
            item.doneAt = item.done ? .now : nil
            if item.done { justDone.insert(id) } else { justDone.remove(id) }
        }
        save()
        guard item.done else { return }
        // Struck through for a moment, then into Bought.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard item.done else { return }
            _ = withAnimation(.snappy(duration: 0.35)) { justDone.remove(id) }
        }
    }

    private func delete(_ item: ShoppingItem) {
        withAnimation(.snappy) { context.delete(item) }
        save()
    }

    private func save() {
        try? context.save()
    }

    private func close() {
        if listening {
            listenTask?.cancel()
            VoiceInput.shared.cancel()
            VoiceInput.expectedWords = nil
            listening = false
        }
        browser.panel = .none
    }
}

/// An item's words, being changed. Return or tapping away keeps them; empty, it goes.
private struct ItemEditor: View {
    @Bindable var item: ShoppingItem
    let finish: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $item.title)
            .font(.system(size: 17))
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { focused = false }
            .onAppear { focused = true }
            .onChange(of: focused) { _, now in if !now { finish(item.title) } }
    }
}
