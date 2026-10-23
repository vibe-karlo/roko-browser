import SwiftData
import SwiftUI

/// What's behind the command bar when no tab is open: your pinned sites,
/// placed low on the screen where the thumb already is.
struct StartView: View {
    @Environment(BrowserModel.self) private var browser
    @Query(sort: \Pin.order) private var pins: [Pin]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack {
            if pins.isEmpty {
                Spacer()
                Text("Pin a site from its page menu and it lives here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
                Spacer()
            } else {
                Spacer()
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(pins) { pin in
                        Button { browser.open(pin) } label: { PinTile(pin: pin) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Unpin", role: .destructive) { browser.unpin(pin) }
                            }
                    }
                }
                .padding(.horizontal, Theme.gutter + 4)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PinTile: View {
    let pin: Pin

    var body: some View {
        VStack(spacing: 8) {
            SiteIcon(host: pin.host, size: 30)
            Text(pin.title.isEmpty ? pin.host : pin.title)
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

/// A site's own icon, bare; before it loads, the host's first letter in plain type.
struct SiteIcon: View {
    let host: String
    var size: CGFloat = 18
    /// For sites you haven't visited (Browse for Me's sources): fetch the icon
    /// from DuckDuckGo's icon service, which roko already uses for search.
    var remote = false

    var body: some View {
        if let image = FaviconStore.shared.icon(for: host) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.22))
        } else if remote, let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high).scaledToFit()
                        .clipShape(.rect(cornerRadius: size * 0.22))
                } else {
                    letter
                }
            }
            .frame(width: size, height: size)
        } else {
            letter
        }
    }

    private var letter: some View {
        Text(host.prefix(1).uppercased())
            .font(.system(size: size * 0.72, weight: .semibold))
            .foregroundStyle(Theme.secondaryInk)
            .frame(width: size, height: size)
    }
}
