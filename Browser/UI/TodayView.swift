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
                ForEach(today.followed) { section in followedView(section) }
                if !today.newsSites.isEmpty || !NewsTopics.chosen.isEmpty {
                    Button("News sites and topics") { choosingSites = true }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                }
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
            DailyReminders.askIfNeeded()
            // Seen this morning: no nudge to look.
            DailyReminders.update(in: context)
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

    @ViewBuilder
    private var news: some View {
        let sites = today.newsSites.filter { !$0.isSection }
        if today.newsSites.isEmpty && NewsTopics.chosen.isEmpty {
            section("Top stories") {
                Text("Choose the news sites you read, sections of them, or topics to follow, and they show up here each morning.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryInk)
                Button("Choose news") { choosingSites = true }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            }
        } else if !sites.isEmpty {
            section("Top stories") {
                if today.top.isEmpty {
                    Text(today.isRefreshing ? "Reading your news sites…" : "No stories yet. Pull down to try again.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(today.top) { story in storyRow(story) }
            }
        }
    }

    /// A followed page ("NK Osijek" on glas-slavonije.hr) or a topic.
    private func followedView(_ followed: FollowedSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let host = followed.host { SiteIcon(host: host, size: 16, remote: true) }
                Text(followed.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
            }
            if followed.stories.isEmpty {
                Text(today.isRefreshing ? "Looking…" : "Nothing new in the last two days.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryInk)
            }
            ForEach(followed.stories) { story in storyRow(story) }
        }
    }

    private func storyRow(_ story: NewsStory) -> some View {
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
                    Text(story.host + (story.published.map { " · " + Self.when($0) } ?? ""))
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

    /// "10 minutes ago", or for a page that only dates its stories by day, "today" / "yesterday".
    private static func when(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        if parts.hour == 12, parts.minute == 0 {
            return Calendar.current.isDateInToday(date) ? "today"
                : Calendar.current.isDateInYesterday(date) ? "yesterday" : date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.relative(presentation: .named))
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

/// Today's news: well-known sites to tick, any other site or one section of
/// it by its address ("glas-slavonije.hr/sport/nk-osijek"), and topics.
struct NewsSitesSheet: View {
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = NewsSite.chosen
    @State private var topics = NewsTopics.chosen
    @State private var address = ""
    @State private var topic = ""
    @State private var finding = false
    @State private var notFound = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(NewsSite.suggestions + chosen.filter { site in !NewsSite.suggestions.contains { $0.id == site.id } }) { site in
                        Button { toggle(site) } label: {
                            HStack(spacing: 12) {
                                SiteIcon(host: site.host, size: 20, remote: true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(site.title).foregroundStyle(Theme.ink)
                                    if site.isSection {
                                        Text(site.host + (site.path ?? "")).font(.footnote).foregroundStyle(Theme.secondaryInk).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if chosen.contains(where: { $0.id == site.id }) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("A site or page, e.g. glas-slavonije.hr/sport/nk-osijek", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(add)
                        if finding { ProgressView() } else {
                            Button("Add", action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } header: {
                    Text("Sites and pages")
                } footer: {
                    Text(notFound ? "Couldn't find news at that address."
                         : "A whole site's stories go into Top stories. A page of a site, like one club's news, gets a section of its own with only its stories.")
                }

                Section {
                    ForEach(topics, id: \.self) { topic in Text(topic) }
                        .onDelete { topics.remove(atOffsets: $0) }
                    HStack {
                        // Names: autocorrect made "Hajduk" into "Handful".
                        TextField("A topic, e.g. NK Osijek", text: $topic)
                            .autocorrectionDisabled()
                            .onSubmit(addTopic)
                        Button("Add", action: addTopic).disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Topics")
                } footer: {
                    Text("Stories about each topic from the major Croatian news sites and yours, picked on this iPhone. Swipe to remove one.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("News")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if chosen != NewsSite.chosen || topics != NewsTopics.chosen {
                            NewsSite.chosen = chosen
                            NewsTopics.chosen = topics
                            changed()
                        }
                        dismiss()
                    }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func toggle(_ site: NewsSite) {
        if let index = chosen.firstIndex(where: { $0.id == site.id }) { chosen.remove(at: index) } else { chosen.append(site) }
    }

    private func add() {
        let typed = address
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        finding = true
        notFound = false
        Task {
            let site = await TodayNews.find(typed)
            finding = false
            guard let site else { notFound = true; return }
            if !chosen.contains(where: { $0.id == site.id }) { chosen.append(site) }
            address = ""
        }
    }

    private func addTopic() {
        let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !topics.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        topics.append(name)
        topic = ""
    }
}
