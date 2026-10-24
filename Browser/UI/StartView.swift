import SwiftData
import SwiftUI

/// What's behind the command bar when no tab is open: your pinned sites,
/// placed low on the screen where the thumb already is.
struct StartView: View {
    @Environment(BrowserModel.self) private var browser
    @Query(sort: \Pin.order) private var pins: [Pin]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

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
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(pins) { pin in
                        let name = pin.title.isEmpty ? pin.host : pin.title
                        Button { browser.open(pin) } label: { PinTile(pin: pin) }
                            .buttonStyle(RowButtonStyle())
                            .accessibilityLabel(name)
                            .contextMenu {
                                Section(name) {
                                    Button("Unpin", role: .destructive) { browser.unpin(pin) }
                                }
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

/// A pin is its site's icon, bare: names cut short to fit under it were noise.
/// A long press says which page it is.
struct PinTile: View {
    let pin: Pin

    var body: some View {
        SiteIcon(host: pin.host, size: 34)
            .frame(maxWidth: .infinity, minHeight: 56)
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
        } else if remote {
            RemoteSiteIcon(host: host, size: size) { letter }
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

/// The icon of a site you haven't visited, from an icon service: the letter
/// until it arrives, and for good if there is none.
private struct RemoteSiteIcon<Fallback: View>: View {
    let host: String
    let size: CGFloat
    @ViewBuilder let fallback: Fallback
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? RemoteIcons.cached(host) {
                Image(uiImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.22))
            } else {
                fallback
            }
        }
        .task(id: host) { image = await RemoteIcons.load(host) }
    }
}

/// Icons for sites you haven't visited (Browse for Me's sources), fetched once
/// per host and kept in memory: DuckDuckGo's icon service first, then Google's.
/// Both answer "no icon" with a 404 that still carries a placeholder picture
/// (DuckDuckGo's is a grey arrow), so only a 200 counts.
enum RemoteIcons {
    private static let cache = NSCache<NSString, UIImage>()
    private static var missing: Set<String> = []

    static func cached(_ host: String) -> UIImage? {
        cache.object(forKey: host as NSString)
    }

    static func load(_ host: String) async -> UIImage? {
        if let image = cached(host) { return image }
        guard !missing.contains(host) else { return nil }
        let services = ["https://icons.duckduckgo.com/ip3/\(host).ico",
                        "https://www.google.com/s2/favicons?domain=\(host)&sz=64"]
        for service in services {
            guard let url = URL(string: service),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { continue }
            cache.setObject(image, forKey: host as NSString)
            return image
        }
        missing.insert(host)
        return nil
    }
}
