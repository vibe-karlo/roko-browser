import AVKit
import SwiftUI

/// What's going on right now, in the dark band under the page (after Lens):
/// sound playing in another tab, parking counting down, a to-do due within the
/// hour. One at a time, in one compact row; with more than one, small dots
/// show where you are and a sideways swipe moves between them. Pull it down
/// and it shrinks to a thin strip that stays live; tap the strip (or pull it
/// up) for the band again, pull the strip down to put that one away.
struct LiveBand: View {
    @Environment(BrowserModel.self) private var browser
    @State private var pull: CGFloat = 0
    @State private var slide: CGFloat = 0

    /// Its height above the home indicator.
    static func height(minimized: Bool) -> CGFloat { minimized ? 30 : 66 }

    private var items: [BrowserModel.LiveItem] { browser.liveItems }
    private var page: Int { min(browser.livePage, max(items.count - 1, 0)) }
    private var minimized: Bool { browser.bandMinimized }

    var body: some View {
        Group {
            if items.indices.contains(page) {
                let item = items[page]
                Group {
                    if minimized { strip(item) } else { row(item) }
                }
                .id(item.id)
                .transition(.asymmetric(insertion: .move(edge: slide < 0 ? .trailing : .leading).combined(with: .opacity),
                                        removal: .opacity))
            }
        }
        .frame(height: Self.height(minimized: minimized))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { dots }
        .clipped()
        .contentShape(.rect)
        .offset(y: pull)
        // Ahead of the buttons: a pull or a swipe starting on one is still that; a tap stays a tap.
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) {
                    pull = max(-20, value.translation.height)
                }
            }
            .onEnded(ended))
        .sensoryFeedback(.selection, trigger: minimized)
        .sensoryFeedback(.selection, trigger: page)
        .environment(\.colorScheme, .dark)
    }

    private func ended(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        withAnimation(.snappy(duration: 0.25)) {
            pull = 0
            if abs(dx) > abs(dy) {
                // Sideways: the next or the one before, if there is one.
                guard items.count > 1, abs(dx) > 36 || abs(value.predictedEndTranslation.width) > 120 else { return }
                slide = dx
                browser.livePage = (page + (dx < 0 ? 1 : -1) + items.count) % items.count
                return
            }
            let down = dy > 30 || value.predictedEndTranslation.height > 110
            let up = dy < -15 || value.predictedEndTranslation.height < -60
            if minimized {
                if up { browser.bandMinimized = false } else if down, items.indices.contains(page) { browser.dismissLive(items[page]) }
            } else if down {
                browser.bandMinimized = true
            }
        }
    }

    /// Where you are among them, when there's more than one.
    @ViewBuilder
    private var dots: some View {
        if items.count > 1, !minimized {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == page ? 0.85 : 0.25))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.top, 4)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func row(_ item: BrowserModel.LiveItem) -> some View {
        switch item {
        case .media(let tab): MediaRow(tab: tab)
        case .parking(let session): ParkingRow(session: session)
        case .todo(let todo): TodoRow(todo: todo)
        }
    }

    /// Pulled down: still live, out of the way. Tap it for the band.
    private func strip(_ item: BrowserModel.LiveItem) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { browser.bandMinimized = false } } label: {
            HStack(spacing: 7) {
                switch item {
                case .media(let tab):
                    Levels(playing: tab.media?.playing == true)
                    Text(tab.media.map { $0.title.isEmpty ? tab.displayTitle : $0.title } ?? tab.displayTitle)
                case .parking(let session):
                    Glyph(.car, size: 13)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(ParkingRow.left(until: session.endsAt, at: context.date)) left")
                            .monospacedDigit()
                    }
                case .todo(let todo):
                    Glyph(.todo, size: 13)
                    Text(todo.title)
                }
                if items.count > 1 {
                    Text("+\(items.count - 1)").foregroundStyle(.white.opacity(0.45))
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Show the band")
    }
}

// MARK: Rows

/// The white circle that leads each row: play and pause, tick, the car.
private func leadButton(_ label: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
    Button(action: action) {
        content()
            .foregroundStyle(.black)
            .frame(width: 38, height: 38)
            .background(.white, in: .circle)
    }
    .accessibilityLabel(label)
}

/// What it is over a line about it; a tap on them goes to `action`.
private func rowText(hint: String, action: @escaping () -> Void,
                     @ViewBuilder title: () -> some View, @ViewBuilder detail: () -> some View) -> some View {
    Button(action: action) {
        VStack(alignment: .leading, spacing: 2) {
            title()
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            detail()
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(RowButtonStyle())
    .accessibilityHint(hint)
}

private func roundButton(_ label: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
    Button(action: action) {
        content()
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.1), in: .circle)
    }
    .accessibilityLabel(label)
}

/// Sound or video in a tab you've left: play and pause, what's playing and
/// where, 15 seconds back and on, Picture in Picture for a video, AirPlay.
private struct MediaRow: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab

    private var media: BrowserTab.Media { tab.media ?? .init(playing: false, isVideo: false, title: "", artist: "") }

    var body: some View {
        HStack(spacing: 8) {
            leadButton(media.playing ? "Pause" : "Play", action: { browser.togglePlayback(tab) }) {
                Image(systemName: media.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    // A triangle's weight sits left of its box: nudged to look centred.
                    .offset(x: media.playing ? 0 : 1)
            }
            rowText(hint: "Go to its tab", action: { browser.select(tab) }) {
                Text(media.title.isEmpty ? tab.displayTitle : media.title)
            } detail: {
                HStack(spacing: 5) {
                    SiteIcon(host: tab.url?.displayHost ?? "", size: 11)
                    Text(media.artist.isEmpty ? tab.url?.displayHost ?? "" : media.artist)
                    Levels(playing: media.playing)
                }
            }
            roundButton("Back 15 seconds", action: { browser.skip(tab, by: -15) }) {
                Image(systemName: "gobackward.15").font(.system(size: 14, weight: .semibold))
            }
            roundButton("Forward 15 seconds", action: { browser.skip(tab, by: 15) }) {
                Image(systemName: "goforward.15").font(.system(size: 14, weight: .semibold))
            }
            if media.isVideo {
                roundButton("Picture in Picture", action: { browser.pictureInPicture(tab) }) {
                    Image(systemName: "pip.enter").font(.system(size: 14, weight: .semibold))
                }
            }
            AirPlayButton()
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: .circle)
                .accessibilityLabel("AirPlay")
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .contextMenu {
            Button { browser.select(tab) } label: { Label("Go to Tab", image: "phosphor/tab") }
            if media.isVideo {
                Button { browser.fullScreen(tab) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            Button(role: .destructive) { browser.closePlayer(tab) } label: { Label("Stop and Close", image: "phosphor/close") }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: media.playing)
    }
}

/// Paid parking counting down: the time left, the zone and plate, and
/// another hour (the text it sends, as from the bar).
private struct ParkingRow: View {
    @Environment(BrowserModel.self) private var browser
    let session: Parking.Session

    /// "1:05:09" or "42:10".
    static func left(until end: Date, at now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func openParking() { browser.handleLink(URL(string: "roko://parking")!) }

    var body: some View {
        HStack(spacing: 8) {
            leadButton("Parking", action: openParking) {
                Glyph(.car, size: 19, weight: 2)
            }
            rowText(hint: "Parking in the bar", action: openParking) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(Self.left(until: session.endsAt, at: context.date)) left")
                }
            } detail: {
                Text([session.zone?.name, Parking.display(session.plate),
                      "until " + session.endsAt.formatted(date: .omitted, time: .shortened)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if Parking.shared.canExtend {
                Button { Parking.shared.extend() } label: {
                    Text("+1 h")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(.white.opacity(0.1), in: .capsule)
                }
                .accessibilityLabel("Add an hour")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .contextMenu {
            Button(role: .destructive) { Parking.shared.end() } label: { Label("End Parking", image: "phosphor/close") }
        }
    }
}

/// A to-do due soon: tick it off, what it is and when.
private struct TodoRow: View {
    @Environment(BrowserModel.self) private var browser
    let todo: Todo
    @State private var ticked = false

    private func when(_ now: Date) -> String {
        guard let time = todo.time else { return "Today" }
        let minutes = Int((time.timeIntervalSince(now) / 60).rounded())
        let clock = time.formatted(date: .omitted, time: .shortened)
        if minutes > 0 { return "At \(clock), in \(minutes) min" }
        if minutes == 0 { return "Now, \(clock)" }
        return "At \(clock), \(-minutes) min ago"
    }

    var body: some View {
        HStack(spacing: 8) {
            leadButton("Done", action: tick) {
                Image(systemName: ticked ? "checkmark" : "circle")
                    .font(.system(size: ticked ? 15 : 17, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
            }
            rowText(hint: "Open To-do", action: { browser.panel = .todos }) {
                Text(todo.title)
            } detail: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(when(context.date))
                }
            }
            roundButton("Open To-do", action: { browser.panel = .todos }) {
                Glyph(.todo, size: 16)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .sensoryFeedback(.success, trigger: ticked)
    }

    /// The tick shows for a moment, then it's done and leaves the band.
    private func tick() {
        withAnimation(.snappy(duration: 0.2)) { ticked = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { browser.complete(todo) }
    }
}

/// Three small level bars that move while sound plays and rest low on pause.
private struct Levels: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(t * (5.2 + Double(index) * 1.7) + Double(index) * 1.3) + 1) / 2
                    Capsule()
                        .fill(.white.opacity(0.75))
                        .frame(width: 2, height: playing && !reduceMotion ? 2 + 7 * wave : 2)
                }
            }
            .frame(height: 9, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// iOS's own AirPlay picker, tinted to the band.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
