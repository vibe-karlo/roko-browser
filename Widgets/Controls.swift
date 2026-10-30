import AppIntents
import SwiftUI
import WidgetKit

/// roko's buttons for Control Center, the Lock Screen and the Action button.
struct NewTabControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "roko.control.newTab") {
            ControlWidgetButton(action: NewTabIntent()) {
                Label("New Tab", systemImage: "plus")
            }
        }
        .displayName("New Tab")
        .description("Opens roko's bar, ready to type or speak.")
    }
}

struct PrivateTabControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "roko.control.privateTab") {
            ControlWidgetButton(action: PrivateTabIntent()) {
                Label("Private Tab", systemImage: "eye.slash")
            }
        }
        .displayName("Private Tab")
        .description("A roko tab that leaves nothing behind.")
    }
}

struct AskRokoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "roko.control.ask") {
            ControlWidgetButton(action: AskRokoIntent()) {
                Label("Ask roko", systemImage: "sparkle.magnifyingglass")
            }
        }
        .displayName("Ask roko")
        .description("Ask a question; roko reads the web and answers.")
    }
}
