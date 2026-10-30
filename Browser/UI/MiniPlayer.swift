import SwiftUI

/// Sound or video playing in a tab you've left, as a slim player resting on
/// the bar: its cover, what it is, how far it's got, play and pause, Picture
/// in Picture for a video, and close. When the bar folds away while you
/// scroll, the player slides down into its place. Tap it to go back to the
/// tab; hold it for skipping and full screen.
struct MiniPlayer: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: BrowserTab

    private var media: BrowserTab.Media { tab.media ?? .init(playing: false, isVideo: false, title: "", artist: "") }

    var body: some View {
        HStack(spacing: 0) {
            Button { browser.select(tab) } label: {
                HStack(spacing: 12) {
                    cover
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title.isEmpty ? tab.displayTitle : media.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(media.artist.isEmpty ? tab.url?.displayHost ?? "" : media.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Go to its tab")

            control(media.playing ? .pause : .play, media.playing ? "Pause" : "Play", size: 22) {
                browser.togglePlayback(tab)
            }
            if media.isVideo {
                control(.pip, "Picture in Picture", size: 20) { browser.pictureInPicture(tab) }
            }
            control(.close, "Close player", size: 17) { browser.closePlayer(tab) }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 58)
        .overlay(alignment: .bottom) { progressLine }
        .barSurface(cornerRadius: Theme.barRadius)
        .compositingGroup()
        .contextMenu {
            Button { browser.select(tab) } label: { Label("Go to Tab", image: "phosphor/tab") }
            Button { browser.skip(tab, by: -15) } label: { Label("Back 15 Seconds", image: "phosphor/skipBack") }
            Button { browser.skip(tab, by: 15) } label: { Label("Forward 15 Seconds", image: "phosphor/skipForward") }
            if media.isVideo {
                Button { browser.fullScreen(tab) } label: { Label("Full Screen", image: "phosphor/desktop") }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: media.playing)
        .animation(.snappy(duration: 0.2), value: media.isVideo)
    }

    /// The page's own picture for what's playing, else its site's icon, round
    /// like a record and turning slowly while it plays; it stops where it is on
    /// pause.
    private var cover: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !media.playing || reduceMotion || media.artwork == nil)) { context in
            disc.rotationEffect(.degrees(reduceMotion || media.artwork == nil ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 16) / 16 * 360))
        }
        .accessibilityHidden(true)
    }

    private var disc: some View {
        AsyncImage(url: media.artwork) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                SiteIcon(host: tab.url?.displayHost ?? "", size: 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(.rect(cornerRadius: 21))
        .overlay(Circle().strokeBorder(Theme.edge))
    }

    /// How far it's got, as a hairline along the bottom of the pill under the
    /// title; it moves on smoothly between the page's once-a-second reports.
    @ViewBuilder
    private var progressLine: some View {
        if media.duration > 0 {
            TimelineView(.animation(minimumInterval: 0.5, paused: !media.playing)) { context in
                GeometryReader { proxy in
                    let track = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.edge)
                        Capsule()
                            .fill(Theme.secondaryInk)
                            .frame(width: max(3, track * media.progress(at: context.date)))
                    }
                }
                .frame(height: 3)
            }
            // From under the title (past the cover: 8 inset, 42 cover, 12 gap)
            // to inside the pill's right curve, so it never crosses the cover.
            .padding(.leading, 8 + 42 + 12)
            .padding(.trailing, Theme.barRadius)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
        }
    }

    private func control(_ glyph: Glyph.Kind, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: size)
                .contentTransition(.opacity)
                .frame(width: 46, height: 52)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }
}
