import SwiftData
import SwiftUI
import UserNotifications

@main
struct BrowserApp: App {
    @State private var browser = BrowserModel()
    /// Made here rather than by .modelContainer(for:), so Notify Me's
    /// background checks reach the same store as the app.
    private let container: ModelContainer

    init() {
        LaunchClock.mark("appInit")
        container = Store.makeContainer()
        // Before launch finishes, so a tap on a notification that opens roko isn't missed.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        SettingsSync.shared.start()
        // iCloud tells roko about changes from other devices with silent
        // pushes, which need no permission.
        if Store.syncs { UIApplication.shared.registerForRemoteNotifications() }
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environment(browser)
                .tint(Theme.accent)
        }
        .modelContainer(container)
        // Notify Me while roko isn't open: iOS wakes it for a few seconds.
        .backgroundTask(.appRefresh(WatchScheduler.taskID)) { [container] in
            await Watcher.runDue(in: container, inBackground: true)
        }
    }
}
