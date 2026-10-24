import SwiftData
import SwiftUI

/// roko's one to-do list, opened by searching "to-do". It sorts itself by
/// when each to-do is for: Overdue, Today, Tomorrow, This week, Later, Someday.
/// Tap the circle to tick one off, tap its words to change them, long-press
/// to move it to another day or delete it. New ones are typed at the bottom,
/// where the thumb is.
struct TodoView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \Todo.createdAt) private var todos: [Todo]
    @State private var draft = ""
    @State private var draftWhen: TodoWhen = .today
    /// Ticked a moment ago: still shown, struck through, so a slip can be undone.
    @State private var justDone: Set<PersistentIdentifier> = []
    @State private var editing: PersistentIdentifier?
    @State private var choosingDate: Todo?

    private var sections: [(TodoSection, [Todo])] {
        let shown = todos.filter { !$0.done || justDone.contains($0.persistentModelID) }
        let grouped = Dictionary(grouping: shown) { TodoSection.of($0) }
        return TodoSection.allCases.compactMap { section in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            // Later is in date order; the rest in the order they were added.
            return (section, section == .later ? items.sorted { ($0.day ?? .distantFuture) < ($1.day ?? .distantFuture) } : items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.bottom, 26)
                if sections.isEmpty {
                    Text("Nothing to do. Add one below.")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
                ForEach(sections, id: \.0) { section, items in
                    sectionView(section, items)
                        .padding(.bottom, 30)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .animation(.snappy(duration: 0.3), value: todos.map(\.persistentModelID))
            .animation(.snappy(duration: 0.3), value: justDone)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .sheet(item: $choosingDate) { todo in
            DayPicker(initial: todo.day ?? .now) { date in
                withAnimation(.snappy) { todo.schedule(.date(date)) }
                save()
            }
        }
        // Pull down past the top to close, as Browse for Me does.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 90
        } action: { _, pulled in
            if pulled { close() }
        }
    }

    // MARK: Sections

    private func sectionView(_ section: TodoSection, _ items: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(section.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(section == .overdue ? Theme.accentText : Theme.secondaryInk)
                Spacer()
                if section == .overdue {
                    Button("Move to Today") {
                        withAnimation(.snappy) { items.forEach { $0.schedule(.today) } }
                        save()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                }
            }
            .padding(.bottom, 8)
            ForEach(items) { todo in
                row(todo, section: section)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    private func row(_ todo: Todo, section: TodoSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button { toggle(todo) } label: {
                TodoCircle(done: todo.done)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            .accessibilityLabel(todo.done ? "Done" : "Not done")
            .padding(.leading, -11)

            VStack(alignment: .leading, spacing: 3) {
                if editing == todo.persistentModelID {
                    TitleEditor(todo: todo) { finished in
                        editing = nil
                        if finished.trimmingCharacters(in: .whitespaces).isEmpty { delete(todo) } else { save() }
                    }
                } else {
                    Text(todo.title)
                        .font(.system(size: 17))
                        .foregroundStyle(todo.done ? Theme.secondaryInk : Theme.ink)
                        .strikethrough(todo.done, color: Theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { if !todo.done { editing = todo.persistentModelID } }
                }
                if section == .later, let day = todo.day {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .contextMenu { menu(for: todo) }
    }

    @ViewBuilder
    private func menu(for todo: Todo) -> some View {
        Button { move(todo, .today) } label: { Label("Today", systemImage: "sun.max") }
        Button { move(todo, .tomorrow) } label: { Label("Tomorrow", systemImage: "sunrise") }
        Button { move(todo, .thisWeek) } label: { Label("This Week", systemImage: "calendar") }
        Button { choosingDate = todo } label: { Label("Choose Date…", systemImage: "calendar.badge.clock") }
        Button { move(todo, .someday) } label: { Label("Someday", systemImage: "archivebox") }
        Divider()
        Button(role: .destructive) { delete(todo) } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                // Return adds it and the keyboard stays up for the next one.
                ReturnKeepingField(placeholder: "New to-do", text: $draft, onReturn: add)
                    .frame(height: 44)
                Menu {
                    Picker("When", selection: $draftWhen) {
                        Text("Today").tag(TodoWhen.today)
                        Text("Tomorrow").tag(TodoWhen.tomorrow)
                        Text("This Week").tag(TodoWhen.thisWeek)
                        Text("Someday").tag(TodoWhen.someday)
                    }
                } label: {
                    Text(Self.label(draftWhen))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("When: \(Self.label(draftWhen))")
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(height: 52)
            .background(Theme.raised, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.edge))

            Button(action: close) {
                Glyph(.close, size: 16, weight: 2)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.canvas)
        .background(alignment: .top) { FadeEdge(color: Theme.canvas) }
    }

    private static func label(_ when: TodoWhen) -> String {
        switch when {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This week"
        case .someday: "Someday"
        case .date(let date): date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    // MARK: Changes

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        withAnimation(.snappy) { context.insert(Todo(title: title, when: draftWhen)) }
        save()
        draft = ""
    }

    private func toggle(_ todo: Todo) {
        let id = todo.persistentModelID
        withAnimation(.snappy(duration: 0.25)) {
            todo.done.toggle()
            todo.doneAt = todo.done ? .now : nil
            if todo.done { justDone.insert(id) } else { justDone.remove(id) }
        }
        save()
        guard todo.done else { return }
        // Struck through for a moment, then it goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard todo.done else { return }
            _ = withAnimation(.snappy(duration: 0.35)) { justDone.remove(id) }
        }
    }

    private func move(_ todo: Todo, _ when: TodoWhen) {
        withAnimation(.snappy) { todo.schedule(when) }
        save()
    }

    private func delete(_ todo: Todo) {
        withAnimation(.snappy) { context.delete(todo) }
        save()
    }

    private func save() {
        try? context.save()
    }

    private func close() {
        browser.panel = .none
    }
}

/// The tick box: a ring, filled with roko's orange and a tick once done.
struct TodoCircle: View {
    let done: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(done ? Theme.accent : Theme.secondaryInk.opacity(0.7), lineWidth: 1.6)
            if done {
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.canvas)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 22, height: 22)
        .sensoryFeedback(.success, trigger: done) { _, now in now }
    }
}

/// A to-do's words, being changed. Return or tapping away keeps them; empty, it goes.
private struct TitleEditor: View {
    @Bindable var todo: Todo
    let finish: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $todo.title, axis: .vertical)
            .font(.system(size: 17))
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { finish(todo.title) }
            .onChange(of: todo.title) { _, title in
                // A vertical field takes Return as a new line: here it finishes.
                if title.contains("\n") {
                    todo.title = title.replacingOccurrences(of: "\n", with: "")
                    focused = false
                }
            }
            .onAppear { focused = true }
            .onChange(of: focused) { _, now in if !now { finish(todo.title) } }
    }
}

/// Choose Date…: a calendar, from today on.
private struct DayPicker: View {
    let initial: Date
    let pick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.accent)
                .padding(.horizontal)
                .navigationTitle("Choose Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            pick(date)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
        .onAppear { date = max(initial, Calendar.current.startOfDay(for: .now)) }
    }
}

/// A one-line field whose Return doesn't put the keyboard away: SwiftUI's
/// always gives up focus on Return, and the first letters typed after it
/// were lost while it came back. UIKit's asks first, and here the answer is no.
private struct ReturnKeepingField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 17)
        field.textColor = UIColor(Theme.ink)
        field.tintColor = UIColor(Theme.accent)
        field.attributedPlaceholder = NSAttributedString(string: placeholder,
                                                         attributes: [.foregroundColor: UIColor(Theme.secondaryInk)])
        field.returnKeyType = .done
        field.autocapitalizationType = .sentences
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ReturnKeepingField

        init(parent: ReturnKeepingField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onReturn()
            return false
        }
    }
}
