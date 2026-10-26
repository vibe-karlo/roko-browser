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
    @Namespace private var barSpace
    /// Read so the list speaks a newly chosen language at once.
    @AppStorage(ListLanguage.key) private var language = ListLanguage.automatic.rawValue

    private var toBuy: [ShoppingItem] {
        items.filter { !$0.done || justDone.contains($0.persistentModelID) }
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
        items.filter { $0.done && !justDone.contains($0.persistentModelID) }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    private var suggested: [ShoppingHabit] {
        Shopping.suggestions(habits, excluding: listed)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let left = items.filter { !$0.done }.count
                Text(Self.toBuy(left))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.bottom, 26)
                    .animation(nil, value: left)
                if aisles.isEmpty {
                    Text(ListLanguage.say("Nothing to buy. Add something below.", "Ništa za kupiti. Dodaj nešto ispod."))
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
        // Pull down past the top to close, as To-do does.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulled in
            if pulled { close() }
        }
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
        if adding {
            VStack(spacing: 0) {
                let completions = Shopping.completions(for: draft, in: habits, excluding: listed)
                if !completions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(completions) { habit in
                            Button {
                                add(habit.title)
                                draft = ""
                            } label: {
                                HStack(spacing: 12) {
                                    Glyph(.plus, size: 13, weight: 2)
                                        .foregroundStyle(Theme.secondaryInk)
                                    Text(habit.title)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.ink)
                                    Spacer(minLength: 0)
                                    Text(Aisle(rawValue: habit.chosenAisle ?? "").map(\.title) ?? Aisle.of(habit.title).title)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineLimit(1)
                                }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ListLanguage.say("Add ", "Dodaj ") + habit.title)
                        }
                    }
                    .padding(.horizontal, Theme.gutter + 18)
                    .padding(.bottom, 6)
                    .background(Theme.canvas)
                    .transition(.opacity)
                }
                HStack(spacing: 10) {
                    ReturnKeepingField(placeholder: ListLanguage.say("Milk, eggs, bread", "Mlijeko, jaja, kruh"), text: $draft) {
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
                       morphs: false, fieldSpace: barSpace)
                .transition(.opacity)
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
        if result.added.isEmpty, !result.already.isEmpty { browser.showToast(Shopping.said(result)) }
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

/// With your pins while there's something to buy: the basket with how many
/// as a notification number. Nothing on the list, and it isn't there.
struct ShoppingPin<Label: View>: View {
    @Environment(BrowserModel.self) private var browser
    @Query(filter: #Predicate<ShoppingItem> { !$0.done }) private var items: [ShoppingItem]
    let size: CGFloat
    @ViewBuilder let frame: (AnyView) -> Label

    init(size: CGFloat, @ViewBuilder frame: @escaping (AnyView) -> Label) {
        self.size = size
        self.frame = frame
    }

    var body: some View {
        if !items.isEmpty {
            Button { browser.panel = .shopping } label: {
                frame(AnyView(CountedGlyph(glyph: .basket, count: items.count, size: size)))
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("Shopping, \(items.count) to buy")
        }
    }
}
