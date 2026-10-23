import SwiftData
import SwiftUI

/// Notify Me for the page on screen, as in Safari: say what to look for (or
/// nothing, for anything new) and how often; roko reads the page from then on
/// and notifies you when it finds it.
struct NotifyMeSheet: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.modelContext) private var context
    @Query private var watches: [Watch]
    let tab: BrowserTab

    @State private var lookFor = ""
    @State private var frequency: WatchFrequency = .daily
    @FocusState private var fieldFocused: Bool

    private var existing: Watch? {
        guard let url = tab.url?.absoluteString else { return nil }
        return watches.first { $0.url == url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notify Me")
                    .font(.system(size: 22, weight: .semibold))
                Text("roko reads \(tab.url?.displayHost ?? "this page") for you and tells you when it changes.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryInk)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Look for")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                TextField("Anything new", text: $lookFor, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(1...3)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Theme.raised, in: .rect(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.edge))
                    // A wrapping field takes Return as a new line: here it's done.
                    .onChange(of: lookFor) { _, text in
                        if text.contains("\n") {
                            lookFor = text.replacingOccurrences(of: "\n", with: "")
                            fieldFocused = false
                        }
                    }
                Text("Such as: size M in stock, a price under €50, a new article about Pula.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faintInk)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Check")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                FrequencyPicker(selection: $frequency)
                Text("iOS picks the exact time, so a check can come later.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faintInk)
            }

            VStack(spacing: 6) {
                Button(action: save) {
                    Text(existing == nil ? "Notify Me" : "Save")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.canvas)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.ink, in: .rect(cornerRadius: 16))
                        .contentShape(.rect)
                }
                .buttonStyle(RowButtonStyle())
                if existing != nil {
                    Button(action: stop) {
                        Text("Stop notifying")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .onAppear {
            if let existing {
                lookFor = existing.lookFor
                frequency = WatchFrequency(rawValue: existing.everyHours) ?? .daily
            }
        }
    }

    private func save() {
        guard let url = tab.url else { return }
        let watch = existing ?? Watch(url: url, title: tab.displayTitle)
        let isNew = existing == nil
        watch.lookFor = lookFor.trimmingCharacters(in: .whitespacesAndNewlines)
        watch.everyHours = frequency.rawValue
        if isNew { context.insert(watch) }
        try? context.save()
        browser.panel = .none
        Task {
            let allowed = await WatchNotifications.requestPermission()
            browser.showToast(allowed ? (isNew ? "roko will let you know" : "Saved") : "Notifications are off for roko in iOS Settings")
            // The page as it is now, to compare every later check with.
            if isNew { await Watcher.begin(watch, in: context) }
            WatchScheduler.schedule(in: context)
        }
    }

    private func stop() {
        guard let existing else { return }
        context.delete(existing)
        try? context.save()
        WatchScheduler.schedule(in: context)
        browser.panel = .none
        browser.showToast("Stopped")
    }
}

/// Hourly, daily or weekly. The choice slides between them, as Browse for
/// Me's Answer / Google switch does.
private struct FrequencyPicker: View {
    @Binding var selection: WatchFrequency
    @Namespace private var marker

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WatchFrequency.allCases) { frequency in
                let isOn = frequency == selection
                Button { selection = frequency } label: {
                    Text(frequency.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isOn ? Theme.ink : Theme.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            if isOn {
                                Capsule().fill(Theme.ink.opacity(0.12))
                                    .matchedGeometryEffect(id: "marker", in: marker)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.raised, in: .capsule)
        .animation(.snappy(duration: 0.28), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
