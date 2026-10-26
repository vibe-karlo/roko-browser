import AppIntents
import SwiftUI
import WidgetKit

/// One of the bar's pinned answers, chosen when the widget is set up.
struct PinnedAnswerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pinned answer"
    static let defaultQuery = PinnedAnswerQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(title)")
    }
}

struct PinnedAnswerQuery: EntityQuery {
    private var all: [PinnedAnswerEntity] {
        (WidgetSnapshot.load()?.answers ?? []).map { PinnedAnswerEntity(id: $0.id, title: $0.title) }
    }

    func entities(for identifiers: [String]) async throws -> [PinnedAnswerEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PinnedAnswerEntity] { all }

    func defaultResult() async -> PinnedAnswerEntity? { all.first }
}

struct PickAnswerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Answer"
    static let description = IntentDescription("One of the answers you pinned in roko's bar.")

    @Parameter(title: "Answer") var answer: PinnedAnswerEntity?
}

struct AnswerEntry: TimelineEntry {
    let date: Date
    let answer: WidgetSnapshot.Answer?
}

/// The answer as the bar last worked it out; it's written again each time
/// the bar shows your pins, so the widget follows without asking the network.
struct AnswerProvider: AppIntentTimelineProvider {
    private static let sample = WidgetSnapshot.Answer(id: "weather in London", title: "14° Partly cloudy in London",
                                                      subtitle: "Feels like 12°, 9° to 16°", icon: "phosphor/wx-partly", updated: .now)

    func placeholder(in context: Context) -> AnswerEntry {
        AnswerEntry(date: .now, answer: Self.sample)
    }

    func snapshot(for configuration: PickAnswerIntent, in context: Context) async -> AnswerEntry {
        AnswerEntry(date: .now, answer: context.isPreview ? Self.sample : answer(for: configuration) ?? Self.sample)
    }

    func timeline(for configuration: PickAnswerIntent, in context: Context) async -> Timeline<AnswerEntry> {
        Timeline(entries: [AnswerEntry(date: .now, answer: answer(for: configuration))], policy: .never)
    }

    private func answer(for configuration: PickAnswerIntent) -> WidgetSnapshot.Answer? {
        let answers = WidgetSnapshot.load()?.answers ?? []
        return answers.first { $0.id == configuration.answer?.id } ?? answers.first
    }
}

/// A pinned answer from the bar, on the Home Screen or the Lock Screen.
struct AnswerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "roko.answer", intent: PickAnswerIntent.self, provider: AnswerProvider()) { entry in
            AnswerWidgetView(entry: entry)
                .containerBackground(for: .widget) { AnswerBackground() }
                .widgetURL(URL(string: "roko://bar"))
        }
        .configurationDisplayName("Answer")
        .description("An answer you pinned in roko's bar: the weather somewhere, a rate, days until.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct AnswerBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // Theme.panel, light and dark.
        scheme == .dark ? Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1B / 255)
                        : Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF2 / 255)
    }
}

private struct AnswerWidgetView: View {
    let entry: AnswerEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let answer = entry.answer {
            switch family {
            case .accessoryInline:
                Text(answer.title)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(answer.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(answer.subtitle).font(.system(size: 13)).lineLimit(1).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    if let icon = answer.icon {
                        Image(icon).resizable().renderingMode(.template).scaledToFit()
                            .frame(width: 22, height: 22)
                    }
                    Spacer(minLength: 0)
                    Text(answer.title)
                        .font(.system(size: family == .systemSmall ? 20 : 24, weight: .semibold).monospacedDigit())
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    Text(answer.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        } else {
            Text(family == .accessoryInline ? "Pin an answer in roko" : "Pin an answer in roko's bar, like the weather somewhere or a rate, to show it here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
