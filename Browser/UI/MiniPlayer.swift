import SwiftUI

/// Sound or video playing in a tab you've left: a small player above the bar,
/// so it plays on while you browse. Tap its name to go back to it; hold it for
/// full screen.
struct MiniPlayer: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab

    private var media: BrowserTab.Media { tab.media ?? .init(playing: false, isVideo: false, title: "", artist: "") }

    var body: some View {
        HStack(spacing: 2) {
            Button { browser.select(tab) } label: {
                HStack(spacing: 10) {
                    SiteIcon(host: tab.url?.displayHost ?? "", size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.title.isEmpty ? tab.displayTitle : media.title)
                            .font(.system(size: 14, weight: .medium))
                        Text(media.artist.isEmpty ? tab.url?.displayHost ?? "" : media.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Go to its tab")

            control(.skipBack, "Back 15 seconds") { browser.skip(tab, by: -15) }
            control(media.playing ? .pause : .play, media.playing ? "Pause" : "Play") { browser.togglePlayback(tab) }
            control(.skipForward, "Forward 15 seconds") { browser.skip(tab, by: 15) }
            if media.isVideo {
                control(.pip, "Picture in Picture") { browser.pictureInPicture(tab) }
            }
            control(.close, "Close player") { browser.closePlayer(tab) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 56)
        .barSurface(cornerRadius: 14)
        .compositingGroup()
        .contextMenu {
            Button("Go to Tab") { browser.select(tab) }
            if media.isVideo {
                Button("Full Screen") { browser.fullScreen(tab) }
                Button("Picture in Picture") { browser.pictureInPicture(tab) }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: media.playing)
    }

    private func control(_ glyph: Glyph.Kind, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: 20)
                .contentTransition(.opacity)
                .frame(width: 40, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }
}
