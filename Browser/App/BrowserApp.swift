import SwiftData
import SwiftUI

@main
struct BrowserApp: App {
    @State private var browser = BrowserModel()

    init() {
        LaunchClock.mark("appInit")
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environment(browser)
                .tint(Theme.accent)
        }
        .modelContainer(for: [Pin.self, HistoryEntry.self, SavedTab.self])
    }
}
