import AppIntents

/// What Siri and Spotlight know roko can do, with no setting up.
struct RokoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewTabIntent(),
                    phrases: ["New tab in \(.applicationName)", "Open a new \(.applicationName) tab"],
                    shortTitle: "New Tab", systemImageName: "plus")
        AppShortcut(intent: PrivateTabIntent(),
                    phrases: ["New private tab in \(.applicationName)", "Browse privately in \(.applicationName)"],
                    shortTitle: "Private Tab", systemImageName: "eye.slash")
        AppShortcut(intent: AskRokoIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask roko", systemImageName: "sparkle.magnifyingglass")
    }
}
