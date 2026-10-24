import SwiftData
import SwiftUI

/// roko's one to-do list, opened by searching "to-do". It sorts itself by
/// when each to-do is for: Overdue, Today, Tomorrow, This week, Later, Someday.
/// Tap the circle to tick one off, tap its words to change them, long-press
/// to move it to another day, give it a time, or delete it; drag it to put it
/// somewhere else in its section or into another. New ones are typed at the bottom,
/// where the thumb is. Pull down past the top to close it.
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
    /// Being dragged (set as a long press lifts it, menu or drag): rows it
    /// passes over make room for it.
    @State private var dragging: Todo?
    /// The Done list at the bottom is open.
    @State private var showsDone = false

    /// Ticked off in the last two weeks, the latest first: there to untick a slip.
    private var finished: [Todo] {
        let since = Date.now.addingTimeInterval(-14 * 86_400)
        return todos
            .filter { $0.done && !justDone.contains($0.persistentModelID) && ($0.doneAt ?? .distantPast) > since }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    private var sections: [(TodoSection, [Todo])] {
        let shown = todos.filter { !$0.done || justDone.contains($0.persistentModelID) }
        let grouped = Dictionary(grouping: shown) { TodoSection.of($0) }
        return TodoSection.allCases.compactMap { section in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            // Later is in date order; the rest in the order they were put in.
            let ordered = items.sorted(by: Todo.listOrder)
            return (section, section == .later ? ordered.sorted { ($0.day ?? .distantFuture) < ($1.day ?? .distantFuture) } : ordered)
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
                if !finished.isEmpty { doneSection }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .animation(.snappy(duration: 0.3), value: todos.map(\.persistentModelID))
            .animation(.snappy(duration: 0.3), value: justDone)
        }
        .scrollDismissesKeyboard(.interactively)
        // Let go between rows: it stays where it was last put.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            dropped()
            return true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .onAppear { DailyReminders.askIfNeeded() }
        .sheet(item: $choosingDate) { todo in
            DayPicker(initial: todo.day ?? .now, time: todo.time) { date, clock in
                withAnimation(.snappy) {
                    todo.schedule(.date(date))
                    todo.setTime(clock)
                }
                save()
                if clock != nil { TodoAlerts.askIfNeeded() }
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
            // Dropped on the heading: first in the section.
            .contentShape(.rect)
            .onDrop(of: [.text], delegate: TodoDrop(view: self, target: nil, section: section))
            ForEach(items) { todo in
                row(todo, section: section)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                    .onDrag {
                        dragging = todo
                        return NSItemProvider(object: todo.title as NSString)
                    }
                    .onDrop(of: [.text], delegate: TodoDrop(view: self, target: todo, section: section))
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
                    Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                         + (todo.timeLabel.map { ", " + $0 } ?? ""))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryInk)
                } else if let time = todo.timeLabel {
                    Text(time)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(section == .overdue ? Theme.accentText : Theme.secondaryInk)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .contextMenu { menu(for: todo) }
    }

    /// Done, folded away under its count; opened, the latest first, each one
    /// a tap from being undone.
    private var doneSection: some View {
        let done = finished
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { showsDone.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(done.count)")
                        .font(.system(size: 15).monospacedDigit())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(showsDone ? 90 : 0))
                    Spacer()
                }
                .foregroundStyle(Theme.secondaryInk)
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsDone ? "Hide done to-dos" : "Show \(done.count) done to-dos")
            if showsDone {
                ForEach(done.prefix(30)) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Button { toggle(todo) } label: {
                            TodoCircle(done: true)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        .accessibilityLabel("Done. Tap to undo")
                        .padding(.leading, -11)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(todo.title)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.secondaryInk)
                                .strikethrough(true, color: Theme.secondaryInk)
                            if let at = todo.doneAt {
                                Text(Calendar.current.isDateInToday(at) ? at.formatted(date: .omitted, time: .shortened)
                                     : at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.faintInk)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .contextMenu {
                        Button(role: .destructive) { delete(todo) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private func menu(for todo: Todo) -> some View {
        Button { move(todo, .today) } label: { Label("Today", systemImage: "sun.max") }
        Button { move(todo, .tomorrow) } label: { Label("Tomorrow", systemImage: "sunrise") }
        Button { move(todo, .thisWeek) } label: { Label("This Week", systemImage: "calendar") }
        Button { choosingDate = todo } label: { Label("Date and Time…", systemImage: "calendar.badge.clock") }
        if todo.time != nil {
            Button { withAnimation(.snappy) { todo.setTime(nil) }; save() } label: { Label("No Time", systemImage: "clock.badge.xmark") }
        }
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
                    // What the words say when they say it ("… on Monday at 13"),
                    // else the picked day.
                    Text(whenLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                        .animation(.snappy(duration: 0.2), value: whenLabel)
                }
                .accessibilityLabel("When: \(whenLabel)")
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(height: 52)
            .background(Theme.raised, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.edge))
        }
        // No close button: pulling the list down past its top closes it.
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.canvas)
        .background(alignment: .top) { FadeEdge(color: Theme.canvas) }
    }

    /// The draft's own day and time, if it names any.
    private var understood: (title: String, when: TodoWhen?, time: DateComponents?)? {
        guard let read = TodoDraft.read(draft), read.when != nil || read.time != nil else { return nil }
        return read
    }

    private var whenLabel: String {
        guard let understood else { return TodoDraft.label(draftWhen) }
        return TodoDraft.label(understood.when ?? draftWhen, understood.time)
    }

    // MARK: Changes

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // "Call Petra on Monday at 13:00": Monday, 13:00, as in the address bar.
        let todo = understood.map { Todo(title: $0.title, when: $0.when ?? draftWhen, at: $0.time) }
            ?? Todo(title: title, when: draftWhen)
        if todo.time != nil { TodoAlerts.askIfNeeded() }
        todo.order = (todos.map(\.order).max() ?? 0) + 1
        withAnimation(.snappy) { context.insert(todo) }
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

    // MARK: Dragging

    /// The dragged to-do takes `target`'s place (or the top of `section`),
    /// joining that section's day if it came from another. Nothing is dropped
    /// into Overdue from elsewhere: that's a day already gone.
    fileprivate func place(at target: Todo?, in section: TodoSection) {
        guard let moving = dragging, moving.persistentModelID != target?.persistentModelID else { return }
        let from = TodoSection.of(moving)
        if section == .overdue, from != .overdue { return }
        withAnimation(.snappy(duration: 0.25)) {
            if from != section {
                switch section {
                case .today: moving.schedule(.today)
                case .tomorrow: moving.schedule(.tomorrow)
                case .thisWeek: moving.schedule(.thisWeek)
                case .someday: moving.schedule(.someday)
                case .later, .overdue: if let day = target?.day ?? sections.first(where: { $0.0 == section })?.1.first?.day {
                    moving.schedule(.date(day))
                }
                }
            }
            var items = (sections.first { $0.0 == section }?.1 ?? []).filter { $0.persistentModelID != moving.persistentModelID }
            let index = target.flatMap { target in items.firstIndex { $0.persistentModelID == target.persistentModelID } } ?? 0
            // Passing a row on the way down puts it after that row.
            let wasAbove = from == section && (sections.first { $0.0 == section }?.1
                .firstIndex { $0.persistentModelID == moving.persistentModelID } ?? 0) <= index
            items.insert(moving, at: target == nil ? 0 : min(wasAbove ? index + 1 : index, items.count))
            for (place, todo) in items.enumerated() { todo.order = Double(place + 1) }
        }
    }

    fileprivate func dropped() {
        dragging = nil
        save()
    }
}

private struct TodoDrop: DropDelegate {
    let view: TodoView
    let target: Todo?
    let section: TodoSection

    func dropEntered(info: DropInfo) {
        view.place(at: target, in: section)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        view.dropped()
        return true
    }
}

extension Todo {
    /// The order a section lists them in: where they were dragged, else as added.
    static func listOrder(_ a: Todo, _ b: Todo) -> Bool {
        (a.order, a.createdAt) < (b.order, b.createdAt)
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

/// Date and Time…: a calendar, from today on, and a time if it has one.
private struct DayPicker: View {
    let initial: Date
    let time: Date?
    let pick: (Date, DateComponents?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var hasTime = false
    @State private var clock = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                Section {
                    Toggle("Time", isOn: $hasTime.animation(.snappy))
                    if hasTime {
                        DatePicker("At", selection: $clock, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    if hasTime { Text("A notification comes 15 minutes before.") }
                }
            }
            .tint(Theme.accent)
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
                .navigationTitle("Date and Time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            pick(date, hasTime ? Calendar.current.dateComponents([.hour, .minute], from: clock) : nil)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .onAppear {
            date = max(initial, Calendar.current.startOfDay(for: .now))
            hasTime = time != nil
            // A new time starts at the next whole hour.
            clock = time ?? Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        }
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
