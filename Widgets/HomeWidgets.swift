import AppIntents
import SwiftUI
import WidgetKit

// roko's colours, light and dark, as in the app's Theme. Not main-actor: SwiftUI
// resolves dynamic colours off the main thread (the app crashed on this once).
nonisolated private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let panel = Color(light: 0xF4F4F2, dark: 0x1A1A1B)
    static let ink = Color(light: 0x0E0E0F, dark: 0xE7E7E4)
    static let secondaryInk = Color(light: 0x5C5C59, dark: 0x8C8C88)
    static let accent = Color(light: 0xE84A10, dark: 0xFF5B1F)
    static let accentText = Color(light: 0xD4570C, dark: 0xFF7A38)
}

// MARK: Timeline

struct HomeEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Now, and again at midnight, when tomorrow's to-dos become today's.
struct HomeProvider: TimelineProvider {
    static let sample: WidgetSnapshot = {
        // Days are kept at their start, as the app writes them.
        let today = Calendar.current.startOfDay(for: .now)
        return WidgetSnapshot(
        items: [
            .init(id: "1", title: "Call the bank", day: today, time: nil),
            .init(id: "2", title: "Buy milk", day: today, time: nil),
            .init(id: "3", title: "Dentist", day: today, time: Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: today)),
        ],
        doneToday: 2,
        weather: .init(temperature: 14, condition: "Partly cloudy", glyph: "wx-partly", high: 17, low: 8,
                       rainChance: 10, place: "Osijek", fetchedAt: .now))
    }()

    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: .now, snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(HomeEntry(date: .now, snapshot: context.isPreview ? Self.sample : (WidgetSnapshot.load() ?? Self.sample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? WidgetSnapshot(items: [], doneToday: 0, weather: nil)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        completion(Timeline(entries: [HomeEntry(date: .now, snapshot: snapshot), HomeEntry(date: midnight, snapshot: snapshot)],
                            policy: .after(midnight)))
    }
}

// MARK: Widgets

/// Today's to-dos, ticked off right on the Home Screen.
struct TodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "roko.todo", provider: HomeProvider()) { entry in
            TodoWidgetView(entry: entry)
                .containerBackground(Color.panel, for: .widget)
                .widgetURL(URL(string: "roko://todo"))
        }
        .configurationDisplayName("To-do")
        .description("What's left for today. Tick one off right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// The weather where you are, and what's left to do today.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "roko.today", provider: HomeProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(Color.panel, for: .widget)
                .widgetURL(URL(string: "roko://todo"))
        }
        .configurationDisplayName("Weather and To-do")
        .description("The weather now, and your to-dos for today.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: Views

private struct TodoWidgetView: View {
    let entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    private var rows: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 9
        }
    }

    var body: some View {
        let due = entry.snapshot.due(on: entry.date)
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            TodoHeader(left: due.count)
            TodoList(items: Array(due.prefix(rows)), more: max(0, due.count - rows), now: entry.date,
                     doneToday: entry.snapshot.doneToday, compact: family == .systemSmall)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodayWidgetView: View {
    let entry: HomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let due = entry.snapshot.due(on: entry.date)
        if family == .systemLarge {
            // The weather across the top, the list under it.
            VStack(alignment: .leading, spacing: 14) {
                WeatherPanel(weather: entry.snapshot.weather, wide: true)
                TodoHeader(left: due.count)
                TodoList(items: Array(due.prefix(7)), more: max(0, due.count - 7), now: entry.date,
                         doneToday: entry.snapshot.doneToday, compact: false)
                Spacer(minLength: 0)
            }
        } else {
            // Side by side: the weather on the left, the list on the right.
            HStack(alignment: .top, spacing: 14) {
                // A little in from the edge; only as wide as "Partly cloudy" needs.
                WeatherPanel(weather: entry.snapshot.weather, wide: false)
                    .frame(width: 84, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 6)
                VStack(alignment: .leading, spacing: 8) {
                    TodoHeader(left: due.count)
                    TodoList(items: Array(due.prefix(3)), more: max(0, due.count - 3), now: entry.date,
                             doneToday: entry.snapshot.doneToday, compact: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// "To-do" and how many are left.
private struct TodoHeader: View {
    let left: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("To-do").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            if left > 0 {
                Text("\(left) left").font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.secondaryInk)
            }
        }
    }
}

private struct TodoList: View {
    let items: [WidgetSnapshot.Item]
    let more: Int
    let now: Date
    let doneToday: Int
    let compact: Bool

    var body: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("All done for today").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
                if doneToday > 0 {
                    Text(doneToday == 1 ? "1 done today" : "\(doneToday) done today")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryInk)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: compact ? 7 : 9) {
                ForEach(items) { item in
                    TodoRow(item: item, now: now, compact: compact)
                }
                if more > 0 {
                    Text("\(more) more").font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
                        .padding(.leading, compact ? 26 : 30)
                }
            }
        }
    }
}

/// A to-do: its tick (a button that ticks it off), its title, and its time
/// or that it's overdue.
private struct TodoRow: View {
    let item: WidgetSnapshot.Item
    let now: Date
    let compact: Bool

    private var overdue: Bool { item.day < Calendar.current.startOfDay(for: now) }

    var body: some View {
        // The tick beside the title's first line, when a narrow title wraps.
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            Button(intent: CompleteTodoIntent(id: item.id)) {
                Circle()
                    .strokeBorder(Color.secondaryInk.opacity(0.7), lineWidth: 1.5)
                    .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tick off \(item.title)")
            Text(item.title)
                .font(.system(size: compact ? 14 : 15))
                .foregroundStyle(Color.ink)
                // Narrow: two lines rather than "Water the pl…".
                .lineLimit(compact ? 2 : 1)
            Spacer(minLength: 4)
            if overdue {
                Text("Overdue").font(.system(size: 12)).foregroundStyle(Color.accentText)
            } else if let time = item.time {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.secondaryInk)
            }
        }
    }
}

/// The weather now: its mark, the temperature large, the sky, the day's range.
private struct WeatherPanel: View {
    let weather: WidgetSnapshot.Weather?
    let wide: Bool

    var body: some View {
        Link(destination: URL(string: "roko://today")!) {
            if let weather {
                if wide {
                    HStack(alignment: .center, spacing: 14) {
                        mark(weather, size: 30)
                        Text("\(Int(weather.temperature.rounded()))°")
                            .font(.system(size: 40, weight: .semibold).monospacedDigit())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weather.condition).font(.system(size: 15, weight: .medium))
                            Text(range(weather)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.secondaryInk)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.ink)
                } else {
                    // The mark on the list's header line, the reading on the
                    // widget's bottom edge, as the list's last row would sit.
                    VStack(alignment: .leading, spacing: 0) {
                        mark(weather, size: 20)
                        Spacer(minLength: 4)
                        Text("\(Int(weather.temperature.rounded()))°")
                            .font(.system(size: 38, weight: .semibold).monospacedDigit())
                        Text(weather.condition).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.top, 2)
                        Text(range(weather)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryInk)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .foregroundStyle(Color.ink)
                }
            } else {
                Text("Open Today for the weather")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryInk)
            }
        }
    }

    private func mark(_ weather: WidgetSnapshot.Weather, size: CGFloat) -> some View {
        Image("phosphor/\(weather.glyph)")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color.ink)
    }

    /// "8° to 14°", with the place when there is one.
    private func range(_ weather: WidgetSnapshot.Weather) -> String {
        let span = "\(Int(weather.low.rounded()))° to \(Int(weather.high.rounded()))°"
        return weather.place.map { wide ? "\(span) · \($0)" : span } ?? span
    }
}
