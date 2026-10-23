import SwiftUI

struct SettingsView: View {
    @Environment(BrowserModel.self) private var browser
    @AppStorage("searchEngine") private var engine: SearchEngine = .google
    @AppStorage("suggestions") private var suggestions = true
    @AppStorage("archivePolicy") private var archive: ArchivePolicy = .day
    @AppStorage(ClaudeClient.enabledKey) private var claudeEnabled = true
    @State private var apiKey = Keychain.claudeAPIKey ?? ""
    @State private var blocking: [ContentBlocker.Category: Bool] = [:]
    @State private var confirmClear = false
    @State private var passkeyStatus = PasskeyAccess.status

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
                    Text("Filter lists: EasyList, EasyPrivacy and Fanboy's Cookie List (CC BY-SA 3.0). Article extraction: Mozilla Readability (Apache 2.0).")
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

/// The home screen icon: roko's marks in a few colours, from the logo design.
private struct AppIconPicker: View {
    /// Asset names; "AppIcon" is the default.
    private static let icons = ["AppIcon", "AppIcon-StarOrange", "AppIcon-StarLight", "AppIcon-StarFlame",
                                "AppIcon-StarBlue", "AppIcon-StarGreen", "AppIcon-StarGold", "AppIcon-Chevrons",
                                "AppIcon-ChevronsGraphite", "AppIcon-Plus", "AppIcon-RollingO"]
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
