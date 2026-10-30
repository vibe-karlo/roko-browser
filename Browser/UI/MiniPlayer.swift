import AVKit
import SwiftUI

/// Sound or video playing in a tab you've left (after Lens): the page lifts
/// into a card and the player lives in the dark band under it, one compact
/// row: play and pause, what's playing and where, 15 seconds back and on,
/// Picture in Picture for a video and AirPlay. Pull it down and it shrinks to
/// a thin strip that keeps playing; tap the strip (or pull it up) for the
/// player again, pull the strip down to stop. Tap the title to go to the tab.
struct PlayerBand: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    @State private var pull: CGFloat = 0

    /// Its height above the home indicator.
    static func height(minimized: Bool) -> CGFloat { minimized ? 30 : 66 }

    private var media: BrowserTab.Media { tab.media ?? .init(playing: false, isVideo: false, title: "", artist: "") }
    private var minimized: Bool { browser.playerMinimized }
    private var title: String { media.title.isEmpty ? tab.displayTitle : media.title }

    var body: some View {
        Group {
            if minimized { strip } else { full }
        }
        .frame(height: Self.height(minimized: minimized))
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .offset(y: pull)
        // Ahead of the buttons: a pull starting on one is still a pull; a tap stays a tap.
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .onChanged { pull = max(-20, $0.translation.height) }
            .onEnded { value in
                let down = value.translation.height > 30 || value.predictedEndTranslation.height > 110
                let up = value.translation.height < -15 || value.predictedEndTranslation.height < -60
                withAnimation(.snappy(duration: 0.25)) {
                    if minimized {
                        if up { browser.playerMinimized = false } else if down { browser.closePlayer(tab) }
                    } else if down {
                        browser.playerMinimized = true
                    }
                    pull = 0
                }
            })
        .contextMenu {
            Button { browser.select(tab) } label: { Label("Go to Tab", image: "phosphor/tab") }
            if media.isVideo {
                Button { browser.fullScreen(tab) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            Button(role: .destructive) { browser.closePlayer(tab) } label: { Label("Stop and Close", image: "phosphor/close") }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: media.playing)
        .sensoryFeedback(.selection, trigger: minimized)
        .environment(\.colorScheme, .dark)
    }

    /// The player, in one row.
    private var full: some View {
        HStack(spacing: 8) {
            Button { browser.togglePlayback(tab) } label: {
                Image(systemName: media.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    // A triangle's weight sits left of its box: nudged to look centred.
                    .offset(x: media.playing ? 0 : 1)
                    .frame(width: 38, height: 38)
                    .background(.white, in: .circle)
            }
            .accessibilityLabel(media.playing ? "Pause" : "Play")

            Button { browser.select(tab) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 5) {
                        SiteIcon(host: tab.url?.displayHost ?? "", size: 11)
                        Text(media.artist.isEmpty ? tab.url?.displayHost ?? "" : media.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Levels(playing: media.playing)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Go to its tab")

            round("gobackward.15", "Back 15 seconds") { browser.skip(tab, by: -15) }
            round("goforward.15", "Forward 15 seconds") { browser.skip(tab, by: 15) }
            if media.isVideo {
                round("pip.enter", "Picture in Picture") { browser.pictureInPicture(tab) }
            }
            AirPlayButton()
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: .circle)
                .accessibilityLabel("AirPlay")
        }
        .padding(.horizontal, 16)
    }

    /// Pulled down: still playing, out of the way. Tap it for the player.
    private var strip: some View {
        Button { withAnimation(.snappy(duration: 0.25)) { browser.playerMinimized = false } } label: {
            HStack(spacing: 7) {
                Levels(playing: media.playing)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Show the player")
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: .circle)
        }
        .accessibilityLabel(label)
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
