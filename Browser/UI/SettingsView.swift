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
    @State private var blocking: [ContentBlocker.Category: Bool] = [:]
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

    /// Says what the choice costs: a language Apple's models write badly goes
    /// to Claude every time, which is slower and paid.
    private var answerLanguageFooter: String {
        guard let language = WritingLanguage.with(code: answerLanguage) else {
            return "Summaries, Browse for Me and Notify Me write in the language of the page or the question."
        }
        return language.appleWritesWell
            ? "Summaries, Browse for Me and Notify Me write in \(language.english)."
            : "Apple's models write \(language.english) poorly, so Claude writes summaries and answers: a few seconds slower than on the iPhone, and paid with your API key. Without a key, they're in English."
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
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: appearance) { Appearance.apply() }
                }

                Section("App icon") {
                    AppIconPicker()
                }

                Section("Search") {
                    Picker("Search engine", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Suggestions while typing", isOn: $suggestions)
                }

                Section {
                    Toggle("Open Today each morning", isOn: $opensToday)
                    Toggle("Reminders", isOn: $reminders)
                        .onChange(of: reminders) { DailyReminders.update(in: context) }
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
                    Text("Today")
                } footer: {
                    Text("The first time you open roko each day: the weather, your calendar, today's to-dos and the news you follow. Search \u{201C}today\u{201D} to see it any time. Reminders, silent and at most two a day: at 8:30 if you haven't looked at Today, and at 16:00 if today's to-dos are still open.")
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
                    Picker("Answer language", selection: $answerLanguage) {
                        Text("Automatic").tag("")
                        ForEach(WritingLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Summaries and answers")
                } footer: {
                    Text(answerLanguageFooter)
                }

                Section {
                    Toggle("Show the link you copied", isOn: $showsCopiedLink)
                    if showsCopiedLink {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Copied links")
                } footer: {
                    Text(showsCopiedLink
                         ? "roko reads the link to show it. In iOS Settings, set Paste from Other Apps to Allow, or iOS asks for each link."
                         : "Off, the address bar offers a Paste button, which opens the link without iOS asking.")
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
                } header: {
                    Text("Notify Me")
                } footer: {
                    Text("roko checks these pages and notifies you when it finds what you asked for. iOS picks the exact times; pages that need their scripts run are checked while roko is open.")
                }

                Section {
                    ForEach(ContentBlocker.Category.allCases) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { blocking[category] ?? ContentBlocker.shared.isEnabled(category) },
                            set: {
                                blocking[category] = $0
                                ContentBlocker.shared.setEnabled(category, $0)
                            }))
                    }
                } header: {
                    Text("Block")
                } footer: {
                    Text("Applies from the next page you load.")
                }

                Section {
                    Toggle("Use Claude", isOn: $claudeEnabled)
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.claudeAPIKey = apiKey }
                        // Still editable while off: the key is kept, just not used.
                        .foregroundStyle(claudeEnabled ? Theme.ink : Theme.secondaryInk)
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text(claudeEnabled
                         ? "Powers Browse for Me and summaries of Croatian pages. Stored only in this iPhone's Keychain."
                         : "Off: nothing is sent to Claude, and Apple's models write every summary and answer. Your key stays saved.")
                }

                Section {
                    LabeledContent("Access") {
                        Text(passkeyLabel).foregroundStyle(Theme.secondaryInk)
                    }
                    if passkeyStatus == .notAsked {
                        Button("Allow passkeys") {
                            Task { passkeyStatus = await PasskeyAccess.request() }
                        }
                    }
                } header: {
                    Text("Passkeys")
                } footer: {
                    Text("Sites can sign you in with passkeys once Apple approves this app as a web browser. Until then their passkey prompts won't appear.")
                }

                if Store.syncs {
                    Section {
                        LabeledContent("Sync") {
                            Text(syncStatus).foregroundStyle(Theme.secondaryInk)
                        }
                    } header: {
                        Text("iCloud")
                    } footer: {
                        Text("Pins, history, settings and what you chose for each site, on every device signed in to your iCloud. Open tabs and Notify Me stay on this iPhone.")
                    }
                    .task { syncStatus = await Self.iCloudStatus() }
                }

                if !shared.isEmpty {
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
                    } header: {
                        Text("Shared pages")
                    } footer: {
                        Text("Browse for Me pages you shared. Swipe one to unshare it: its link stops working.")
                    }
                }

                Section("Tabs") {
                    Picker("Close unused tabs", selection: $archive) {
                        ForEach(ArchivePolicy.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Clear history", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Clear all browsing history?", isPresented: $confirmClear) {
                            Button("Clear history", role: .destructive) { browser.clearHistory() }
                        }
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
    private static let icons = ["AppIcon", "AppIcon-StarOrange", "AppIcon-StarLight", "AppIcon-StarFlame",
                                "AppIcon-StarBlue", "AppIcon-StarGreen", "AppIcon-StarGold", "AppIcon-Chevrons",
                                "AppIcon-ChevronsGraphite", "AppIcon-Plus", "AppIcon-RollingO",
                                "AppIcon-EclipseCream", "AppIcon-EclipseOnOrange", "AppIcon-EclipseOrange"]
    @State private var current = UIApplication.shared.alternateIconName ?? "AppIcon"
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
