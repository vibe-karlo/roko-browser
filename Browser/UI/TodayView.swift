import SwiftData
import SwiftUI

/// Today: the first thing roko shows on a new day, and there whenever you
/// search "today". The weather where you are, what's left on your calendar,
/// today's to-dos and the top stories from the news sites you chose. Pull
/// down to freshen it; it freshens itself when it's over an hour old.
struct TodayView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \Todo.createdAt) private var todos: [Todo]
    @State private var today = TodayModel.shared
    @State private var choosingSites = false
    @State private var calendarAllowed = TodayCalendar.isAllowed
    /// Ticked a moment ago: still shown, struck through.
    @State private var justDone: Set<PersistentIdentifier> = []

    private var dueTodos: [Todo] {
        todos.filter { $0.isDueNow || justDone.contains($0.persistentModelID) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                header
                if calendarAllowed || !TodayCalendar.wasAsked { calendar }
                if !dueTodos.isEmpty { toDos }
                news
                Text("Weather by Open-Meteo.com")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faintInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            // Clear of the fade above the footer, scrolled to the end.
            .padding(.bottom, 70)
            .animation(.snappy(duration: 0.3), value: today.top)
            .animation(.snappy(duration: 0.3), value: justDone)
        }
        .refreshable { await today.refreshFromPull() }
        // The page fades out above the footer, rather than the footer getting
        // a solid floor that would cut the morning light off with an edge.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 56)
                Color.clear.frame(height: 64)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay(alignment: .top) { StatusBarFade(color: Theme.canvas) }
        .background {
            ZStack {
                Theme.canvas
                // Morning light, low at the bottom edge. Still: it isn't working on anything.
                WorkingGlow(progress: 0, isActive: true, breathes: false)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Theme.ink)
        .onAppear {
            today.appeared()
            TodayModel.markShown()
        }
        .sheet(isPresented: $choosingSites) {
            NewsSitesSheet { today.sitesChanged() }
        }
    }

    // MARK: Header and weather

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 34, weight: .bold))
                Text(Date.now.formatted(.dateTime.day().month(.wide)))
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.secondaryInk)
            }
            if let weather = today.weather {
                weatherView(weather)
            } else if TodayLocation.shared.isDenied {
                Text("Allow location for roko in iOS Settings to see the weather here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func weatherView(_ weather: TodayWeather) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image("phosphor/\(weather.glyph)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                Text("\(Int(weather.temperature.rounded()))°")
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                VStack(alignment: .leading, spacing: 2) {
                    Text(weather.condition + (weather.place.map { " in \($0)" } ?? ""))
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text("Up to \(Int(weather.high.rounded()))°, down to \(Int(weather.low.rounded()))°"
                         + (weather.rainChance >= 30 ? " · rain \(weather.rainChance)%" : ""))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 22) {
                    ForEach(weather.hours) { hour in
                        VStack(spacing: 8) {
                            Text(hour.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(Theme.secondaryInk)
                            Image("phosphor/\(TodayWeather.glyph(hour.code, isDay: hour.isDay))")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                            Text("\(Int(hour.temperature.rounded()))°")
                                .font(.system(size: 15, weight: .medium).monospacedDigit())
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    // MARK: Calendar

    private var calendar: some View {
        section("Calendar") {
            if !calendarAllowed {
                Button("Show today's calendar") {
                    Task { calendarAllowed = await TodayCalendar.requestAccess(); today.appeared() }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accentText)
            } else if today.events.isEmpty {
                Text("Nothing else on your calendar today.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(today.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 15).monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.system(size: 17))
                            if let location = event.location {
                                Text(location)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondaryInk)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: To-do

    private var toDos: some View {
        section("To-do") {
            ForEach(dueTodos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button { toggle(todo) } label: {
                        TodoCircle(done: todo.done)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                    .padding(.leading, -11)
                    Text(todo.title)
                        .font(.system(size: 17))
                        .foregroundStyle(todo.done ? Theme.secondaryInk : Theme.ink)
                        .strikethrough(todo.done, color: Theme.secondaryInk)
                    Spacer(minLength: 0)
                    if TodoSection.of(todo) == .overdue {
                        Text("Overdue")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accentText)
                    }
                }
                .transition(.opacity)
            }
            Button("All to-dos") { browser.panel = .todos }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 2)
        }
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

    // MARK: News

    private var news: some View {
        section("Top stories") {
            if today.newsSites.isEmpty {
                Text("Choose the news sites you read, and their most important stories show up here each morning.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryInk)
                Button("Choose news sites") { choosingSites = true }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            } else {
                if today.top.isEmpty {
                    Text(today.isRefreshing ? "Reading your news sites…" : "No stories yet. Pull down to try again.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(today.top) { story in
                    Button { open(story.link) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            SiteIcon(host: story.host, size: 18, remote: true)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(story.title)
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                Text(story.host + (story.published.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                    .padding(.bottom, 6)
                }
                Button("News sites") { choosingSites = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func open(_ url: URL) {
        browser.panel = .none
        browser.open(url, inNewTab: true)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            content()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if today.isRefreshing {
                    Text("Freshening…")
                } else if let refreshed = today.refreshedAt {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryInk)
            Spacer(minLength: 8)
            Button { browser.panel = .none } label: {
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
    }
}

/// Today's news sites: well-known ones to tick, and any other by its address.
struct NewsSitesSheet: View {
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = NewsSite.chosen
    @State private var address = ""
    @State private var finding = false
    @State private var notFound = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(NewsSite.suggestions + chosen.filter { site in !NewsSite.suggestions.contains { $0.host == site.host } }) { site in
                        Button {
                            if let index = chosen.firstIndex(where: { $0.host == site.host }) {
                                chosen.remove(at: index)
                            } else {
                                chosen.append(site)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                SiteIcon(host: site.host, size: 20, remote: true)
                                Text(site.host).foregroundStyle(Theme.ink)
                                Spacer()
                                if chosen.contains(where: { $0.host == site.host }) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Today reads their newest stories and picks the most important on this iPhone.")
                }
                Section {
                    HStack {
                        TextField("Another site, e.g. telegram.hr", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(add)
                        if finding { ProgressView() } else {
                            Button("Add", action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } footer: {
                    if notFound { Text("Couldn't find news on that site.") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("News sites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if chosen != NewsSite.chosen {
                            NewsSite.chosen = chosen
                            changed()
                        }
                        dismiss()
                    }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func add() {
        let typed = address
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        finding = true
        notFound = false
        Task {
            let site = await TodayNews.findFeed(for: typed)
            finding = false
            guard let site else { notFound = true; return }
            if !chosen.contains(where: { $0.host == site.host }) { chosen.append(site) }
            address = ""
        }
    }
}
