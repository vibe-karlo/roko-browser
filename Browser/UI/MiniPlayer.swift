import AVKit
import SwiftUI

/// Sound or video playing in a tab you've left (after Lens): the page lifts
/// into a card and the player lives in the dark band under it. Play and pause,
/// 15 seconds back and on, Picture in Picture for a video and AirPlay; under
/// them the site, what's playing and its levels moving while it plays. Tap the
/// line to go back to the tab, pull the band down to close it, hold it for
/// full screen.
struct PlayerBand: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    @State private var pull: CGFloat = 0

    /// Its height above the home indicator.
    static let height: CGFloat = 112

    private var media: BrowserTab.Media { tab.media ?? .init(playing: false, isVideo: false, title: "", artist: "") }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 36, height: 5)
                .padding(.top, 7)

            HStack(spacing: 10) {
                Button { browser.togglePlayback(tab) } label: {
                    Image(systemName: media.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                        // A triangle's weight sits left of its box: nudged to look centred.
                        .offset(x: media.playing ? 0 : 1.5)
                        .frame(width: 46, height: 46)
                        .background(.white, in: .circle)
                }
                .accessibilityLabel(media.playing ? "Pause" : "Play")
                round("gobackward.15", "Back 15 seconds") { browser.skip(tab, by: -15) }
                round("goforward.15", "Forward 15 seconds") { browser.skip(tab, by: 15) }
                Spacer(minLength: 0)
                if media.isVideo {
                    round("pip.enter", "Picture in Picture") { browser.pictureInPicture(tab) }
                }
                AirPlayButton()
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.1), in: .circle)
                    .accessibilityLabel("AirPlay")
            }
            .padding(.top, 8)

            Button { browser.select(tab) } label: {
                HStack(spacing: 8) {
                    SiteIcon(host: tab.url?.displayHost ?? "", size: 15)
                    Text(media.title.isEmpty ? tab.displayTitle : media.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .layoutPriority(1)
                    Text(media.artist.isEmpty ? tab.url?.displayHost ?? "" : media.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 6)
                    Levels(playing: media.playing)
                }
                .lineLimit(1)
                .frame(height: 26)
                .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Go to its tab")
            .padding(.top, 6)
        }
        .padding(.horizontal, 22)
        .frame(height: Self.height, alignment: .top)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .offset(y: pull)
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { pull = max(0, $0.translation.height) }
            .onEnded { value in
                if value.translation.height > 50 || value.predictedEndTranslation.height > 140 {
                    browser.closePlayer(tab)
                }
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) { pull = 0 }
            })
        .contextMenu {
            Button { browser.select(tab) } label: { Label("Go to Tab", image: "phosphor/tab") }
            if media.isVideo {
                Button { browser.fullScreen(tab) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            Button(role: .destructive) { browser.closePlayer(tab) } label: { Label("Stop and Close", image: "phosphor/close") }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: media.playing)
        .environment(\.colorScheme, .dark)
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
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
                        .frame(width: 2.5, height: playing && !reduceMotion ? 3 + 8 * wave : 3)
                }
            }
            .frame(height: 11, alignment: .bottom)
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
