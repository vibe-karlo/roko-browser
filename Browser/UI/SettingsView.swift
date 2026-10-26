import CloudKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \Watch.createdAt) private var watches: [Watch]
    @AppStorage("searchEngine") private var engine: SearchEngine = .google
    @AppStorage("suggestions") private var suggestions = true
    @AppStorage(CopiedLink.showKey) private var showsCopiedLink = false
    @AppStorage(Appearance.key) private var appearance: Appearance = .system
    @AppStorage(AnswerLanguage.key) private var answerLanguage = ""
    @State private var keptLanguages = UserDefaults.standard.stringArray(forKey: AnswerLanguage.keptKey) ?? []
    @State private var shared = AnswerSharing.all
    @AppStorage(TodayModel.openKey) private var opensToday = true
    @AppStorage(DailyReminders.key) private var reminders = true
    @State private var choosingNewsSites = false
    @State private var choosingCalendars = false
    @State private var choosingWeatherPlace = false
    @State private var weatherPlace = WeatherPlace.fixed?.name ?? "My location"
    @AppStorage("archivePolicy") private var archive: ArchivePolicy = .day
    @AppStorage(ClaudeClient.enabledKey) private var claudeEnabled = true
    @State private var apiKey = Keychain.claudeAPIKey ?? ""
    @AppStorage(Preferences.holdToTalkKey) private var holdToTalk = true
    @AppStorage(Preferences.voiceLanguagesKey) private var voiceLanguages: Preferences.VoiceLanguages = .both
    @AppStorage(Preferences.launcherTicksKey) private var launcherTicks = true
    @AppStorage(Preferences.pullToSummarizeKey) private var pullToSummarize = true
    @AppStorage(Preferences.todoAlertsKey) private var todoAlerts = true
    @State private var confirmClear = false
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

    /// Takes a shared page down; the list shows what's still shared afterwards.
    private func unshare(_ page: AnswerSharing.Shared) {
        shared.removeAll { $0.id == page.id }
        Task {
            do { try await AnswerSharing.unshare(page) } catch { browser.showToast(error.localizedDescription) }
            shared = AnswerSharing.all
        }
    }

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

    private var passkeyLabel: String {
        switch passkeyStatus {
        case .allowed: "Allowed"
        case .denied: "Turned off in iOS Settings"
        case .notAsked: "Not allowed yet"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: appearance) { Appearance.apply() }
                    NavigationLink {
                        Form { AppIconPicker() }
                            .scrollContentBackground(.hidden)
                            .background(Theme.panel)
                            .navigationTitle("App icon")
                    } label: {
                        Text("App icon")
                    }
                }

                Section {
                    Picker("Search engine", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Suggestions while typing", isOn: $suggestions)
                    Toggle("Show the link you copied", isOn: $showsCopiedLink)
                    if showsCopiedLink {
                        Button("Allow pasting in iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    Toggle("Tick as rows go by", isOn: $launcherTicks)
                } header: {
                    Text("Address bar")
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

                Section {
                    Toggle("Pull further to summarize", isOn: $pullToSummarize)
                    Picker("Close unused tabs", selection: $archive) {
                        ForEach(ArchivePolicy.allCases) { Text($0.title).tag($0) }
                    }
                    NavigationLink {
                        BlockingSettings()
                    } label: {
                        LabeledContent("Block", value: blockingSummary)
                    }
                } header: {
                    Text("Pages")
                } footer: {
                    Text(pullToSummarize
                         ? "Pull a page down to reload it; keep pulling and let go to summarize it."
                         : "Pulling a page down only reloads it.")
                }

                Section {
                    Toggle("Open Today each morning", isOn: $opensToday)
                    Toggle("Morning and afternoon nudges", isOn: $reminders)
                        .onChange(of: reminders) { DailyReminders.update(in: context) }
                    Toggle("Alert before a to-do's time", isOn: $todoAlerts)
                        .onChange(of: todoAlerts) { TodoAlerts.update() }
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
                } header: {
                    Text("Today and to-dos")
                } footer: {
                    Text("Nudges are silent, at most two a day: at 8:30 if you haven't looked at Today, at 16:00 if to-dos are still open. To-do alerts come 15 minutes before, with sound.")
                }
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

                Section {
                    NavigationLink {
                        AnswerLanguageSettings(chosen: $answerLanguage, kept: $keptLanguages)
                    } label: {
                        LabeledContent("Answer language", value: languageSummary)
                    }
                    Toggle("Use Claude", isOn: $claudeEnabled)
                    if claudeEnabled {
                        SecureField("Claude API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Keychain.claudeAPIKey = apiKey }
                    }
                    NavigationLink {
                        WatchesSettings()
                    } label: {
                        LabeledContent("Notify Me", value: watches.isEmpty ? "None" : "\(watches.count)")
                    }
                } header: {
                    Text("Summaries and answers")
                } footer: {
                    Text(answerLanguageFooter + (claudeEnabled
                         ? " Claude powers Browse for Me; the key stays in this iPhone's Keychain."
                         : " Claude off: nothing is sent to it, and your key stays saved."))
                }

                Section {
                    if Store.syncs {
                        LabeledContent("iCloud sync") {
                            Text(syncStatus).foregroundStyle(Theme.secondaryInk)
                        }
                        .task { syncStatus = await Self.iCloudStatus() }
                    }
                    LabeledContent("Passkeys") {
                        Text(passkeyLabel).foregroundStyle(Theme.secondaryInk)
                    }
                    if passkeyStatus == .notAsked {
                        Button("Allow passkeys") {
                            Task { passkeyStatus = await PasskeyAccess.request() }
                        }
                    }
                    if !shared.isEmpty {
                        NavigationLink {
                            SharedPagesSettings(shared: $shared, unshare: unshare)
                        } label: {
                            LabeledContent("Shared pages", value: "\(shared.count)")
                        }
                    }
                    Button("Clear history", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Clear all browsing history?", isPresented: $confirmClear) {
                            Button("Clear history", role: .destructive) { browser.clearHistory() }
                        }
                } header: {
                    Text("Privacy and sync")
                } footer: {
                    Text((Store.syncs ? "Pins, history and settings sync through your iCloud; open tabs and Notify Me stay here. " : "")
                         + "Passkeys work once Apple approves roko as a web browser.")
                }

                Section {
                    Text("Filter lists: EasyList, EasyPrivacy and Fanboy's Cookie List (CC BY-SA 3.0). Cookie pop-ups: DuckDuckGo Autoconsent, with Consent-O-Matic's rules (MPL 2.0). Article extraction: Mozilla Readability (Apache 2.0).")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Keychain.claudeAPIKey = apiKey
                        browser.panel = .none
                    }
                }
            }
        }
        .presentationBackground(Theme.panel)
        .onDisappear { Keychain.claudeAPIKey = apiKey }
    }

    /// How many kinds of things are blocked, for the row.
    private var blockingSummary: String {
        let on = ContentBlocker.Category.allCases.filter(ContentBlocker.shared.isEnabled).count
        return on == ContentBlocker.Category.allCases.count ? "All" : on == 0 ? "Off" : "\(on) of \(ContentBlocker.Category.allCases.count)"
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
        .navigationTitle("Block")
    }
}

/// Pages roko checks for you.
private struct WatchesSettings: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query(sort: \Watch.createdAt) private var watches: [Watch]

    var body: some View {
        Form {
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
        return "Nothing yet · checked \(checked.formatted(.relative(presentation: .named)))"
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
