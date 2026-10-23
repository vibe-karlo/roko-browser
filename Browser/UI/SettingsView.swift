import SwiftUI

struct SettingsView: View {
    @Environment(BrowserModel.self) private var browser
    @AppStorage("searchEngine") private var engine: SearchEngine = .google
    @AppStorage("suggestions") private var suggestions = true
    @AppStorage("archivePolicy") private var archive: ArchivePolicy = .day
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
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.claudeAPIKey = apiKey }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Powers Browse for Me, and summaries when Apple Intelligence isn't available. Stored only in this iPhone's Keychain.")
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
