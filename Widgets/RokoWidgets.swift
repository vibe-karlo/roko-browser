import AlarmKit
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RokoWidgets: WidgetBundle {
    var body: some Widget {
        TodoWidget()
        TodayWidget()
        AnswerWidget()
        ParkingLiveActivity()
        CookTimerLiveActivity()
        // Control Center, the Lock Screen and the Action button.
        NewTabControl()
        PrivateTabControl()
        AskRokoControl()
    }
}

/// Paid parking running down: the time left, large, and when it ends; a tap
/// opens roko's bar on it, "Add an hour" writes the next text.
struct ParkingLiveActivity: Widget {
    /// roko's orange, as in the app (Theme.accent, dark).
    private static let orange = Color(red: 0xC9 / 255, green: 0x4A / 255, blue: 0x2E / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingActivityAttributes.self) { context in
            LockScreen(context: context, orange: Self.orange)
                .activityBackgroundTint(Color(red: 0x18 / 255, green: 0x17 / 255, blue: 0x16 / 255))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "roko://parking"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.zone).font(.system(size: 17, weight: .semibold))
                        Text(plate(context.attributes.plate)).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(endsAt: context.state.endsAt, size: 28)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Footer(context: context, orange: Self.orange)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                Text("P").font(.system(size: 15, weight: .heavy)).foregroundStyle(Self.orange)
            } compactTrailing: {
                Countdown(endsAt: context.state.endsAt, size: 15)
                    .frame(maxWidth: 52)
            } minimal: {
                Text("P").font(.system(size: 15, weight: .heavy)).foregroundStyle(Self.orange)
            }
            .widgetURL(URL(string: "roko://parking"))
        }
    }
}

/// "OS123AB" → "OS 123 AB".
private func plate(_ plate: String) -> String {
    var groups: [String] = []
    for character in plate {
        if let last = groups.last?.last, last.isLetter == character.isLetter {
            groups[groups.count - 1].append(character)
        } else {
            groups.append(String(character))
        }
    }
    return groups.joined(separator: " ")
}

private struct LockScreen: View {
    let context: ActivityViewContext<ParkingActivityAttributes>
    let orange: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.zone)
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(context.attributes.city) · \(plate(context.attributes.plate))")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 12)
                Countdown(endsAt: context.state.endsAt, size: 40)
            }
            Footer(context: context, orange: orange)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// When it ends, and the way to add to it.
private struct Footer: View {
    let context: ActivityViewContext<ParkingActivityAttributes>
    let orange: Color

    var body: some View {
        HStack {
            Text(context.isStale ? "Paid time is up" : "Paid until " + context.state.endsAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            if context.state.canExtend, let url = URL(string: "roko://parking/extend") {
                Link(destination: url) {
                    Text("Add an hour")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(orange)
                }
            }
        }
    }
}

/// Counts down to the end on its own, second by second; nothing needs updating.
private struct Countdown: View {
    let endsAt: Date
    let size: CGFloat

    var body: some View {
        Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true)
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// A timer from Cook Mode counting down. iOS rings it; this is only what it shows meanwhile.
struct CookTimerLiveActivity: Widget {
    /// The recipe colour, as in Cook Mode (PageKind.recipe, dark).
    private static let apricot = Color(red: 0xE8 / 255, green: 0xB9 / 255, blue: 0x8A / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CookTimerMetadata>.self) { context in
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.metadata?.recipe ?? "Cook Mode")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Step \(context.attributes.metadata?.step ?? 1)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                CookCountdown(mode: context.state.mode, size: 34)
                    .foregroundStyle(Self.apricot)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .activityBackgroundTint(Color(red: 0x18 / 255, green: 0x17 / 255, blue: 0x16 / 255))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.metadata?.recipe ?? "Cook Mode")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CookCountdown(mode: context.state.mode, size: 28)
                        .foregroundStyle(Self.apricot)
                        .padding(.trailing, 6)
                }
            } compactLeading: {
                Image(systemName: "fork.knife").foregroundStyle(Self.apricot)
            } compactTrailing: {
                CookCountdown(mode: context.state.mode, size: 15)
                    .foregroundStyle(Self.apricot)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "fork.knife").foregroundStyle(Self.apricot)
            }
        }
    }
}

private struct CookCountdown: View {
    let mode: AlarmPresentationState.Mode
    let size: CGFloat

    var body: some View {
        Group {
            switch mode {
            case .countdown(let countdown):
                Text(timerInterval: Date.now...max(countdown.fireDate, .now), countsDown: true)
            case .paused(let paused):
                Text(Duration.seconds(paused.totalCountdownDuration - paused.previouslyElapsedDuration).formatted(.time(pattern: .minuteSecond)))
            default:
                Text("Time's up")
            }
        }
        .font(.system(size: size, weight: .semibold).monospacedDigit())
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
    }
}
