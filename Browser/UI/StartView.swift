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
                Text("Pin a site from the page tools and it lives here.")
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

    var body: some View {
        if let image = FaviconStore.shared.icon(for: host) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.22))
        } else {
            Text(host.prefix(1).uppercased())
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: size, height: size)
        }
    }
}
