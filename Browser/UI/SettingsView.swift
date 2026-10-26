import CloudKit
import SwiftData
import SwiftUI
import UserNotifications
import WebKit

/// Settings: what roko has saved you, then a short list of places, each with
/// what it's set to now. The switches live on the page of the thing they
/// change, so this first screen stays one screen.
struct SettingsView: View {
    @Environment(BrowserModel.self) private var browser
    @Query(sort: \Watch.createdAt) private var watches: [Watch]
    @AppStorage("searchEngine") private var engine: SearchEngine = .google
    @AppStorage(Appearance.key) private var appearance: Appearance = .system
    @AppStorage("archivePolicy") private var archive: ArchivePolicy = .day
    @AppStorage(AnswerLanguage.key) private var answerLanguage = ""
    @AppStorage(RemindersSync.enabledKey) private var remindersOn = false
    @AppStorage(ListLanguage.key) private var shoppingLanguage: ListLanguage = .automatic
    @State private var apiKey = Keychain.claudeAPIKey ?? ""
    @State private var plates = Parking.shared.plates
    @State private var notifications = "On"
    @State private var changedSites = SitesSettings.sites().count

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { SavedPage() } label: { SavedSummary() }
                }

                Section {
                    link(.search, "Search engine", engine.name) { SearchSettings() }
                    link(.microphone, "Address bar and voice") { BarSettings() }
                    link(.palette, "Appearance", appearance.title) { AppearanceSettings() }
                    link(.appIcon, "App icon") {
                        Form { AppIconPicker() }.settingsPage("App icon")
                    }
                    link(.tab, "Tabs", archive.title) { TabsSettings() }
                }

                Section {
                    link(.today, "Today") { TodaySettings() }
                    link(.todo, "To-dos", remindersOn ? "Reminders on" : nil) { TodoSettings() }
                    link(.basket, "Shopping", shoppingLanguage.title) { ShoppingSettings() }
                    link(.summarize, "Summaries and answers", WritingLanguage.with(code: answerLanguage)?.name ?? "Automatic") {
                        AnswersSettings(apiKey: $apiKey)
                    }
                    link(.bell, "Notify Me", watches.isEmpty ? "None" : watches.count == 1 ? "1 page" : "\(watches.count) pages") {
                        WatchesSettings()
                    }
                    link(.car, "Parking", plates.first.map(Parking.display) ?? "None") {
                        Form { ParkingSection() }.settingsPage("Parking")
                    }
                } header: {
                    Text("Your things")
                }

                Section {
                    link(.blocking, "Blocking", blockingSummary) { BlockingSettings() }
                    link(.globe, "Sites", changedSites == 0 ? "None changed" : changedSites == 1 ? "1 changed" : "\(changedSites) changed") {
                        SitesSettings()
                    }
                    link(.broom, "Clear browsing data") { ClearDataSettings() }
                    link(.key, "Passkeys and sync") { PrivacySettings() }
                } header: {
                    Text("Privacy")
                }

                Section {
                    link(.notification, "Notifications", notifications) { NotificationSettings() }
                    link(.info, "About roko", AboutSettings.version) { AboutSettings() }
                }
            }
            .settingsPage("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Keychain.claudeAPIKey = apiKey
                        browser.panel = .none
                    }
                }
            }
            // Values on the rows, fresh each time a page is closed.
            .onAppear {
                plates = Parking.shared.plates
                changedSites = SitesSettings.sites().count
                Task { notifications = await NotificationSettings.summary() }
            }
        }
        .presentationBackground(Theme.panel)
        .onDisappear { Keychain.claudeAPIKey = apiKey }
    }

    /// A row that opens a page: its mark, its name, and what it's set to now.
    private func link(_ glyph: Glyph.Kind, _ title: String, _ value: String? = nil,
                      @ViewBuilder page: @escaping () -> some View) -> some View {
        NavigationLink(destination: page) {
            HStack(spacing: 14) {
                Glyph(glyph, size: 21)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let value {
                    // Whole or not at all: a clipped "Hrvat…" says nothing.
                    ViewThatFits {
                        Text(value)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
            }
        }
    }

    /// How many kinds of things are blocked, for the row.
    private var blockingSummary: String {
        let on = ContentBlocker.Category.allCases.filter(ContentBlocker.shared.isEnabled).count
        return on == ContentBlocker.Category.allCases.count ? "All" : on == 0 ? "Off" : "\(on) of \(ContentBlocker.Category.allCases.count)"
    }
}

extension View {
    /// A settings page on roko's panel, under its title.
    func settingsPage(_ title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle(title)
    }
}

// MARK: Time saved

/// What roko has saved you, as the first row: the time, large.
private struct SavedSummary: View {
    @State private var totals = SavedStats.totals

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if totals.seconds > 0 {
                Text(SavedStats.duration(totals.seconds))
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text(totals.since.map { "saved since \($0.formatted(.dateTime.day().month(.wide)))" } ?? "saved")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                Text("Nothing saved yet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Cookie pop-ups, summaries and answers add up here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .onReceive(NotificationCenter.default.publisher(for: SavedStats.changed)) { _ in totals = SavedStats.totals }
    }
}

/// Where the time came from, each with its count.
private struct SavedPage: View {
    @State private var totals = SavedStats.totals
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                row("Cookie pop-ups", detail: "\(totals.cookieBars) answered · " + count(totals.cookieClicks, "click"),
                    seconds: totals.cookieSeconds)
                row("Summaries", detail: count(totals.summaries, "page"), seconds: totals.summarySeconds)
                row("Browse for Me", detail: count(totals.answers, "answer"), seconds: totals.answerSeconds)
                row("Answers in the bar", detail: count(totals.instant, "answer") + ": weather, sums, rates, time zones",
                    seconds: totals.instantSeconds)
            } header: {
                Text(SavedStats.duration(totals.seconds) + (totals.since.map { " since \($0.formatted(.dateTime.day().month(.wide)))" } ?? ""))
            } footer: {
                Text("Estimates: 3 seconds a click, reading at 230 words a minute, a search plus a minute for each page Browse for Me read, and 10 to 20 seconds for each answer in the bar. Only counts, on this iPhone.")
            }
            Section {
                Button("Start Counting Again", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Start counting again from today?", isPresented: $confirmReset) {
                        Button("Start Counting Again", role: .destructive) {
                            SavedStats.reset()
                            totals = SavedStats.totals
                        }
                    }
            }
        }
        .settingsPage("Time saved")
        .onReceive(NotificationCenter.default.publisher(for: SavedStats.changed)) { _ in totals = SavedStats.totals }
    }

    private func count(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    private func row(_ title: String, detail: String, seconds: Double) -> some View {
        LabeledContent {
            Text(SavedStats.duration(seconds)).monospacedDigit()
        } label: {
            Text(title)
            Text(detail).monospacedDigit()
        }
    }
}

// MARK: Pages

private struct SearchSettings: View {
    @AppStorage("searchEngine") private var engine: SearchEngine = .google
    @AppStorage("suggestions") private var suggestions = true

    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: $engine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Toggle("Suggestions while typing", isOn: $suggestions)
            } footer: {
                Text(suggestions ? "What you type is sent to \(engine.name) for suggestions as you type." : "Nothing is sent until you search.")
            }
        }
        .settingsPage("Search engine")
    }
}

private struct BarSettings: View {
    @AppStorage(CopiedLink.showKey) private var showsCopiedLink = false
    @AppStorage(Preferences.launcherTicksKey) private var launcherTicks = true
    @AppStorage(Preferences.holdToTalkKey) private var holdToTalk = true
    @AppStorage(Preferences.voiceLanguagesKey) private var voiceLanguages: Preferences.VoiceLanguages = .both

    var body: some View {
        Form {
            Section {
                Toggle("Show the link you copied", isOn: $showsCopiedLink)
                if showsCopiedLink {
                    Button("Allow pasting in iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Toggle("Tick as rows go by", isOn: $launcherTicks)
            } footer: {
                Text(showsCopiedLink
                     ? "To show a copied link without iOS asking each time, set Paste from Other Apps to Allow."
                     : "Off, the bar offers a Paste button instead, which iOS never asks about.")
            }
            Section {
                Toggle("Hold + to speak", isOn: $holdToTalk)
                if holdToTalk {
                    Picker("Listen for", selection: $voiceLanguages) {
                        ForEach(Preferences.VoiceLanguages.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text(holdToTalk
                     ? "Questions go to Browse for Me, site names open the site, the rest is searched."
                     : "Off, + only opens the address bar.")
            }
        }
        .settingsPage("Address bar and voice")
    }
}

private struct AppearanceSettings: View {
    @AppStorage(Appearance.key) private var appearance: Appearance = .system

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: appearance) { Appearance.apply() }
            }
        }
        .settingsPage("Appearance")
    }
}

private struct TabsSettings: View {
    @AppStorage("archivePolicy") private var archive: ArchivePolicy = .day
    @AppStorage(Preferences.pullToSummarizeKey) private var pullToSummarize = true

    var body: some View {
        Form {
            Section {
                Picker("Close unused tabs", selection: $archive) {
                    ForEach(ArchivePolicy.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Pull further to summarize", isOn: $pullToSummarize)
            } footer: {
                Text(pullToSummarize
                     ? "Pull a page down to reload it; keep pulling and let go to summarize it."
                     : "Pulling a page down only reloads it.")
            }
        }
        .settingsPage("Tabs")
    }
}

private struct TodaySettings: View {
    @AppStorage(TodayModel.openKey) private var opensToday = true
    @State private var choosingNewsSites = false
    @State private var choosingCalendars = false
    @State private var choosingWeatherPlace = false
    @State private var weatherPlace = WeatherPlace.fixed?.name ?? "My location"

    var body: some View {
        Form {
            Section {
                Toggle("Open Today each morning", isOn: $opensToday)
            }
            Section {
                Button("News sites and topics") { choosingNewsSites = true }
                    .foregroundStyle(Theme.ink)
                if TodayCalendar.isAllowed {
                    Button("Calendars") { choosingCalendars = true }
                        .foregroundStyle(Theme.ink)
                }
                Button { choosingWeatherPlace = true } label: {
                    LabeledContent("Weather", value: weatherPlace)
                }
                .foregroundStyle(Theme.ink)
            }
        }
        .settingsPage("Today")
        .sheet(isPresented: $choosingNewsSites) {
            NewsSitesSheet { TodayModel.shared.sitesChanged() }
        }
        .sheet(isPresented: $choosingCalendars) {
            CalendarsSheet { TodayModel.shared.appeared() }
        }
        .sheet(isPresented: $choosingWeatherPlace) {
            WeatherPlaceSheet {
                TodayModel.shared.weatherPlaceChanged()
                weatherPlace = WeatherPlace.fixed?.name ?? "My location"
            }
        }
    }
}

private struct TodoSettings: View {
    var body: some View {
        Form {
            Section {
                RemindersRow()
            } footer: {
                Text("With Reminders on, your to-dos are also in a Reminders list, on every device with your iCloud. Alerts and nudges are in Notifications.")
            }
        }
        .settingsPage("To-dos")
    }
}

private struct ShoppingSettings: View {
    @Environment(\.modelContext) private var context
    @AppStorage(ListLanguage.key) private var language: ListLanguage = .automatic
    @Query private var habits: [ShoppingHabit]
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(ListLanguage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Aisles and the list's own words are in this language. What you type is understood in English and Croatian either way.")
            }
            Section {
                Button("Forget What You Buy", role: .destructive) { confirmForget = true }
                    .disabled(habits.isEmpty)
                    .confirmationDialog("Forget what you buy?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) {
                            habits.forEach(context.delete)
                            try? context.save()
                        }
                    } message: {
                        Text("Suggestions start over, and aisles you chose for things go back to roko's.")
                    }
            } footer: {
                Text(habits.isEmpty ? "Nothing learned yet." : "roko knows \(habits.count) things you buy and how often, on this iPhone.")
            }
        }
        .settingsPage("Shopping")
    }
}

private struct AnswersSettings: View {
    @Binding var apiKey: String
    @AppStorage(AnswerLanguage.key) private var answerLanguage = ""
    @State private var keptLanguages = UserDefaults.standard.stringArray(forKey: AnswerLanguage.keptKey) ?? []
    @AppStorage(ClaudeClient.enabledKey) private var claudeEnabled = true

    /// The chosen language, then the kept ones, by their own names: "Hrvatski, English".
    private var languageSummary: String {
        guard let chosen = WritingLanguage.with(code: answerLanguage) else { return "Automatic" }
        let kept = keptLanguages.filter { $0 != answerLanguage }.compactMap { WritingLanguage.with(code: $0)?.name }
        return ([chosen.name] + kept).joined(separator: ", ")
    }

    /// Says what the choice costs: a language Apple's models write badly goes
    /// to Claude every time, which is slower and paid.
    private var answerLanguageFooter: String {
        guard let language = WritingLanguage.with(code: answerLanguage) else {
            return "Summaries, Browse for Me and Notify Me write in the language of the page or the question."
        }
        let kept = keptLanguages.filter { $0 != answerLanguage }.compactMap { WritingLanguage.with(code: $0)?.english }
        let rule = kept.isEmpty
            ? "Summaries, Browse for Me and Notify Me write in \(language.english)."
            : "Pages in \(([language.english] + kept).formatted(.list(type: .or))) are written about in their own language; any other in \(language.english)."
        return language.appleWritesWell
            ? rule
            : rule + " Apple's models write \(language.english) poorly, so Claude writes summaries and answers: a few seconds slower than on the iPhone, and paid with your API key. Without a key, they're in English."
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AnswerLanguageSettings(chosen: $answerLanguage, kept: $keptLanguages)
                } label: {
                    LabeledContent("Answer language", value: languageSummary)
                }
            } footer: {
                Text(answerLanguageFooter)
            }
            Section {
                Toggle("Use Claude", isOn: $claudeEnabled)
                if claudeEnabled {
                    SecureField("Claude API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.claudeAPIKey = apiKey }
                }
            } footer: {
                Text(claudeEnabled
                     ? "Claude powers Browse for Me; the key stays in this iPhone's Keychain."
                     : "Claude off: nothing is sent to it, and your key stays saved.")
            }
        }
        .settingsPage("Summaries and answers")
        .onDisappear { Keychain.claudeAPIKey = apiKey }
    }
}

/// Every site where something differs from everywhere else: cookies accepted,
/// blocking off, a zoom. Swipe one to set it back.
struct SitesSettings: View {
    struct Site: Identifiable {
        let host: String
        let changes: [String]
        var id: String { host }
    }

    @State private var sites = SitesSettings.sites()

    static func sites() -> [Site] {
        var changes: [String: [String]] = [:]
        for (host, reason) in ConsentHandler.shared.acceptedSites() {
            changes[host, default: []].append(reason == .chosen ? "Cookies allowed" : "Cookies accepted, it needed them")
        }
        for (host, what) in ContentBlocker.shared.allowances() { changes[host, default: []] += what }
        for (host, level) in PageZoom.all() { changes[host, default: []].append("Zoom \(Int((level * 100).rounded()))%") }
        return changes.map { Site(host: $0.key, changes: $0.value) }.sorted { $0.host < $1.host }
    }

    var body: some View {
        Form {
            Section {
                if sites.isEmpty {
                    Text("Every site is treated the same. Choices you make in a page's menu, and sites where roko had to accept cookies, show up here.")
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(sites) { site in
                    HStack(spacing: 12) {
                        SiteIcon(host: site.host, size: 20, remote: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.host).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(site.changes.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        Button("Reset", role: .destructive) { reset(site) }
                    }
                }
            } footer: {
                if !sites.isEmpty { Text("Swipe a site to treat it like every other: cookies rejected, everything blocked, 100% zoom.") }
            }
        }
        .settingsPage("Sites")
    }

    private func reset(_ site: Site) {
        ConsentHandler.shared.setAccepted(nil, for: site.host)
        ContentBlocker.shared.forgetAllowances(for: site.host)
        PageZoom.forget(site.host)
        withAnimation(.snappy) { sites = Self.sites() }
    }
}

/// History, cookies and cached files, from a time on.
private struct ClearDataSettings: View {
    enum Span: String, CaseIterable, Identifiable {
        case hour, today, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hour: "The last hour"
            case .today: "Today"
            case .all: "All time"
            }
        }
        var since: Date {
            switch self {
            case .hour: .now.addingTimeInterval(-3600)
            case .today: Calendar.current.startOfDay(for: .now)
            case .all: .distantPast
            }
        }
    }

    @Environment(BrowserModel.self) private var browser
    @State private var span = Span.hour
    @State private var history = true
    @State private var cookies = false
    @State private var cache = true
    @State private var confirming = false
    /// Just cleared: said on the button, as the bar's toast sits behind Settings.
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Picker("From", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("History", isOn: $history)
                Toggle("Cookies and site data", isOn: $cookies)
                Toggle("Cached images and files", isOn: $cache)
            } footer: {
                Text(cookies ? "Clearing cookies signs you out of sites, and they ask about cookies again." : "Open tabs stay open.")
            }
            Section {
                Button(cleared ? "Cleared" : "Clear", role: .destructive) { confirming = true }
                    .disabled(cleared || (!history && !cookies && !cache))
                    .sensoryFeedback(.success, trigger: cleared) { _, now in now }
                    .confirmationDialog("Clear \(what) from \(span.title.lowercased())?", isPresented: $confirming,
                                        titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { Task { await clear() } }
                    }
            }
        }
        .settingsPage("Clear browsing data")
    }

    private var what: String {
        [history ? "history" : nil, cookies ? "cookies" : nil, cache ? "cached files" : nil]
            .compactMap { $0 }.formatted(.list(type: .and))
    }

    private func clear() async {
        let since = span.since
        if history { browser.clearHistory(since: since) }
        var types: Set<String> = []
        if cookies {
            types.formUnion([WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                             WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                             WKWebsiteDataTypeServiceWorkerRegistrations])
        }
        if cache {
            types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
                             WKWebsiteDataTypeOfflineWebApplicationCache])
        }
        if !types.isEmpty { await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: since) }
        cleared = true
        try? await Task.sleep(for: .seconds(2))
        cleared = false
    }
}

private struct PrivacySettings: View {
    @Environment(BrowserModel.self) private var browser
    @State private var shared = AnswerSharing.all
    @State private var passkeyStatus = PasskeyAccess.status
    @State private var syncStatus = "Checking…"

    /// Whether this iPhone can sync: signed in to iCloud, and iCloud allowed for roko.
    private static func iCloudStatus() async -> String {
        #if ICLOUD_SYNC
        switch try? await CKContainer(identifier: Store.cloudContainer).accountStatus() {
        case .available: return "On"
        case .noAccount: return "Sign in to iCloud"
        case .restricted: return "Not allowed on this iPhone"
        case .temporarilyUnavailable: return "Paused: check iCloud in Settings"
        default: return "Unavailable"
        }
        #else
        return "Off"
        #endif
    }

    private var passkeyLabel: String {
        switch passkeyStatus {
        case .allowed: "Allowed"
        case .denied: "Turned off in iOS Settings"
        case .notAsked: "Not allowed yet"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Passkeys") {
                    Text(passkeyLabel).foregroundStyle(Theme.secondaryInk)
                }
                if passkeyStatus == .notAsked {
                    Button("Allow passkeys") {
                        Task { passkeyStatus = await PasskeyAccess.request() }
                    }
                }
            } footer: {
                Text("Passkeys work once Apple approves roko as a web browser.")
            }
            Section {
                LabeledContent("iCloud sync") {
                    Text(syncStatus).foregroundStyle(Theme.secondaryInk)
                }
                .task { syncStatus = await Self.iCloudStatus() }
                if !shared.isEmpty {
                    NavigationLink {
                        SharedPagesSettings(shared: $shared, unshare: unshare)
                    } label: {
                        LabeledContent("Shared pages", value: "\(shared.count)")
                    }
                }
            } footer: {
                Text(Store.syncs ? "Pins, history and settings sync through your iCloud; open tabs and Notify Me stay here."
                     : "Everything stays on this iPhone.")
            }
        }
        .settingsPage("Passkeys and sync")
    }

    /// Takes a shared page down; the list shows what's still shared afterwards.
    private func unshare(_ page: AnswerSharing.Shared) {
        shared.removeAll { $0.id == page.id }
        Task {
            do { try await AnswerSharing.unshare(page) } catch { browser.showToast(error.localizedDescription) }
            shared = AnswerSharing.all
        }
    }
}

/// Every notification roko sends, in one place, and whether iOS lets it.
private struct NotificationSettings: View {
    @Environment(\.modelContext) private var context
    @AppStorage(DailyReminders.key) private var nudges = true
    @AppStorage(Preferences.todoAlertsKey) private var todoAlerts = true
    @State private var allowed = true

    /// For the row: off in iOS, or how many kinds are on.
    static func summary() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied ? "Off in iOS" : "On"
    }

    var body: some View {
        Form {
            if !allowed {
                Section {
                    Text("Notifications are off for roko in iOS Settings, so none of these arrive.")
                        .foregroundStyle(Theme.ink)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .foregroundStyle(Theme.accentText)
                }
            }
            Section {
                Toggle("Alert before a to-do's time", isOn: $todoAlerts)
                    .onChange(of: todoAlerts) { TodoAlerts.update() }
                Toggle("Morning and afternoon nudges", isOn: $nudges)
                    .onChange(of: nudges) { DailyReminders.update(in: context) }
            } footer: {
                Text("To-do alerts come 15 minutes before, with sound. Nudges are silent, at most two a day: at 8:30 if you haven't looked at Today, at 16:00 if to-dos are still open.")
            }
            Section {
                NavigationLink { WatchesSettings() } label: { Text("Notify Me") }
            } footer: {
                Text("Pages you watch notify you when they change, or show what you asked for.")
            }
        }
        .settingsPage("Notifications")
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        allowed = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus != .denied
    }
}

private struct AboutSettings: View {
    static var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "") + " (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    private let credits: [(String, String)] = [
        ("Filter lists", "EasyList, EasyPrivacy and Fanboy's Cookie List (CC BY-SA 3.0)"),
        ("Cookie pop-ups", "DuckDuckGo Autoconsent, with Consent-O-Matic's rules (MPL 2.0)"),
        ("Article extraction", "Mozilla Readability (Apache 2.0)"),
        ("Icons", "Phosphor Icons (MIT)"),
        ("Parking zones", "© OpenStreetMap contributors (ODbL)"),
        ("Weather", "Open-Meteo.com (CC BY 4.0)"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
            }
            Section {
                ForEach(credits, id: \.0) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credit.0).foregroundStyle(Theme.ink)
                        Text(credit.1).font(.footnote).foregroundStyle(Theme.secondaryInk)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Built with")
            }
        }
        .settingsPage("About roko")
    }
}

/// To-dos kept in step with a list in Apple Reminders, and so on every
/// device signed in to iCloud.
private struct RemindersRow: View {
    @AppStorage(RemindersSync.enabledKey) private var on = false
    @State private var listName = RemindersSync.isOn ? RemindersSync.list()?.title : nil
    @State private var choosing = false
    @State private var denied = false

    var body: some View {
        Toggle("Sync with Reminders", isOn: Binding(get: { on }, set: { wanted in
            guard wanted else {
                RemindersSync.turnOff()
                on = false
                return
            }
            Task {
                guard await RemindersSync.requestAccess() else {
                    denied = true
                    return
                }
                on = true
                listName = RemindersSync.list()?.title
                RemindersSync.schedule(after: .zero)
            }
        }))
        .alert("Reminders isn't allowed", isPresented: $denied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Allow roko full access to Reminders in iOS Settings to keep your to-dos there too.")
        }
        if on {
            Button { choosing = true } label: {
                LabeledContent("List", value: listName ?? "roko")
            }
            .foregroundStyle(Theme.ink)
            .confirmationDialog("Keep to-dos in", isPresented: $choosing, titleVisibility: .visible) {
                ForEach(RemindersSync.lists(), id: \.calendarIdentifier) { list in
                    Button(list.title) {
                        RemindersSync.choose(list)
                        listName = list.title
                    }
                }
            } message: {
                Text("To-dos and this list are kept the same, both ways. Changing it links your to-dos to the new list.")
            }
        }
    }
}

/// Registrations for paying parking by text. The first is the one sent.
private struct ParkingSection: View {
    @State private var parking = Parking.shared
    @State private var newPlate = ""

    var body: some View {
        Section {
            ForEach(parking.plates, id: \.self) { plate in
                HStack {
                    Text(Parking.display(plate)).monospacedDigit()
                    Spacer()
                    if plate == parking.plates.first, parking.plates.count > 1 {
                        Text("Used").foregroundStyle(Theme.secondaryInk)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy) { parking.makeDefault(plate) } }
                .accessibilityAddTraits(plate == parking.plates.first ? .isSelected : [])
            }
            .onDelete { parking.removePlates(at: $0) }
            TextField("Add a registration, like OS 123 AB", text: $newPlate)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit {
                    withAnimation(.snappy) { parking.addPlate(newPlate) }
                    newPlate = ""
                }
        } header: {
            Text("Parking")
        } footer: {
            Text("In Osijek, type parking in the bar: roko finds your zone and writes the text with your registration, for you to send. The time left then shows on the Lock Screen."
                 + (parking.plates.count > 1 ? " Tap a registration to use it." : ""))
        }
    }
}

/// What summaries and answers are written in: one language, and the
/// languages left as they are.
private struct AnswerLanguageSettings: View {
    @Binding var chosen: String
    @Binding var kept: [String]

    var body: some View {
        Form {
            Section {
                Picker("Write in", selection: $chosen) {
                    Text("Automatic").tag("")
                    ForEach(WritingLanguage.all) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(chosen.isEmpty
                     ? "Automatic writes about every page in its own language. Choose one to have the rest translated into it."
                     : "Pages in other languages are written about in this one, except those you keep below.")
            }

            // Always shown, so it's clear more than one language can stay as it
            // is; dimmed until there's a language to translate the rest into.
            Section {
                ForEach(WritingLanguage.all.filter { $0.code != chosen }) { language in
                    Button {
                        if kept.contains(language.code) { kept.removeAll { $0 == language.code } } else { kept.append(language.code) }
                        UserDefaults.standard.set(kept, forKey: AnswerLanguage.keptKey)
                    } label: {
                        LabeledContent(language.name) {
                            if kept.contains(language.code) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(chosen.isEmpty ? Theme.secondaryInk : Theme.ink)
                    }
                    .accessibilityAddTraits(kept.contains(language.code) ? .isSelected : [])
                }
            } header: {
                Text("Keep as they are")
            } footer: {
                Text(chosen.isEmpty
                     ? "Choose a language to write in first. Pages in the languages ticked here then stay in their own."
                     : "A page in one of these is summarized and answered in its own language, not translated.")
            }
            .disabled(chosen.isEmpty)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Answer language")
    }
}

/// What roko keeps off pages, each kind on its own.
private struct BlockingSettings: View {
    @State private var blocking: [ContentBlocker.Category: Bool] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(ContentBlocker.Category.allCases) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { blocking[category] ?? ContentBlocker.shared.isEnabled(category) },
                        set: {
                            blocking[category] = $0
                            ContentBlocker.shared.setEnabled(category, $0)
                        }))
                }
            } footer: {
                Text("Applies from the next page you load.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Blocking")
    }
}

/// Pages roko checks for you.
private struct WatchesSettings: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \Watch.createdAt) private var watches: [Watch]
    /// What's keeping Notify Me from working fully, if anything.
    @State private var blocked: String?
    @State private var canFix = false

    var body: some View {
        Form {
            if let blocked, !watches.isEmpty {
                Section {
                    Text(blocked).foregroundStyle(Theme.ink)
                    if canFix {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .foregroundStyle(Theme.accentText)
                    }
                }
            }
            Section {
                if watches.isEmpty {
                    Text("None yet. In a page's menu, choose Notify Me.")
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(watches) { watch in
                    Button {
                        if let url = URL(string: watch.url) { browser.open(url, inNewTab: true) }
                    } label: {
                        WatchRow(watch: watch)
                    }
                }
                .onDelete { offsets in
                    offsets.map { watches[$0] }.forEach(context.delete)
                    try? context.save()
                    WatchScheduler.schedule(in: context)
                }
            } footer: {
                Text("roko checks these pages and notifies you when it finds what you asked for. iOS picks the exact times; pages that need their scripts run are checked while roko is open. Swipe one to stop.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Notify Me")
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    /// Notifications off, Background App Refresh off, or Low Power Mode: each
    /// stops Notify Me without a word, so say so here.
    private func check() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            blocked = "Notifications are off for roko, so it can't tell you what it finds."
            canFix = true
        } else if UIApplication.shared.backgroundRefreshStatus != .available {
            blocked = ProcessInfo.processInfo.isLowPowerModeEnabled
                ? "Low Power Mode pauses checks while roko is closed. Pages are checked when you open it."
                : "Background App Refresh is off for roko, so pages are only checked when you open it."
            canFix = !ProcessInfo.processInfo.isLowPowerModeEnabled
        } else {
            blocked = nil
            canFix = false
        }
    }
}

/// Browse for Me pages you shared.
private struct SharedPagesSettings: View {
    @Environment(BrowserModel.self) private var browser
    @Binding var shared: [AnswerSharing.Shared]
    let unshare: (AnswerSharing.Shared) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(shared) { page in
                    Button {
                        browser.open(page.url, inNewTab: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title).foregroundStyle(Theme.ink).lineLimit(1)
                            Text("\(page.url.displayHost)\(page.url.path()) · \(page.date.formatted(.relative(presentation: .named)))")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button("Unshare", role: .destructive) { unshare(page) }
                    }
                }
            } footer: {
                Text("Swipe one to unshare it: its link stops working.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Shared pages")
    }
}

/// A watched page: which, what for and how often, then the last thing found.
private struct WatchRow: View {
    let watch: Watch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SiteIcon(host: watch.host, size: 20, remote: true)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(watch.title.isEmpty ? watch.host : watch.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text((watch.lookFor.isEmpty ? "Anything new" : watch.lookFor) + " · "
                     + (WatchFrequency(rawValue: watch.everyHours)?.name ?? "Daily"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(2)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faintInk)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if let news = watch.lastNews, let at = watch.lastNewsAt {
            return "\(news) · \(at.formatted(.relative(presentation: .named)))"
        }
        guard let checked = watch.lastChecked else { return "Not checked yet" }
        // iOS runs no web views for an app in the background.
        let when = watch.needsRendering ? " · checked while roko is open" : ""
        return "Nothing yet · checked \(checked.formatted(.relative(presentation: .named)))" + when
    }
}

/// The home screen icon: roko's marks in a few colours, from the logo design.
private struct AppIconPicker: View {
    /// Asset names; "AppIcon" is the default.
    private static let icons = ["AppIcon", "AppIcon-StarOrange", "AppIcon-StarFlame",
                                "AppIcon-ChevronsGraphite", "AppIcon-Plus", "AppIcon-RollingO",
                                "AppIcon-EclipseCream", "AppIcon-EclipseOnOrange", "AppIcon-EclipseOrange",
                                "AppIcon-Ro", "AppIcon-RoOnOrange", "AppIcon-Octagon", "AppIcon-OctagonOnOrange",
                                "AppIcon-Wordmark", "AppIcon-WordmarkOnOrange"]
    /// An icon no longer offered counts as the default.
    @State private var current = UIApplication.shared.alternateIconName.flatMap { icons.contains($0) ? $0 : nil } ?? "AppIcon"
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Self.icons, id: \.self) { name in
                Button {
                    guard name != current else { return }
                    current = name
                    UIApplication.shared.setAlternateIconName(name == "AppIcon" ? nil : name)
                } label: {
                    Image("iconpreview/\(name)")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                        // The chosen one sits in a ring of the accent, clear of its edge.
                        .padding(4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 17)
                                .strokeBorder(name == current ? Theme.accent : .clear, lineWidth: 2)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name == "AppIcon" ? "Default icon" : String(name.dropFirst(8)))
                .accessibilityAddTraits(name == current ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
