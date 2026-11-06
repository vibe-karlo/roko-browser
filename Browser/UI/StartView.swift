import SwiftData
import SwiftUI

/// What's there when no tab is open: roko at rest in its light, and low on the
/// screen, where the thumb already is, your pinned sites and the screens of your own
/// that roko keeps: the way into them with nothing open. Under it the band and the
/// bar, as under a page. The light holds still: it's two pictures, drawn once, and
/// nothing runs here.
struct StartView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// In a band like every page. An open Duo keeps the bar floating, on one side of its fold.
    var docked = true
    @Query(sort: \Pin.order) private var pins: [Pin]
    @Query private var todos: [Todo]

    private static let perRow = 5
    private var sideways: Bool { verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { proxy in
            let foot = docked ? Theme.barHeight + 5 + max(proxy.safeAreaInsets.bottom - 20, 9) : Theme.barHeight + 4 + proxy.safeAreaInsets.bottom
            content(width: min(proxy.size.width, 480))
                .padding(.bottom, 20)
                .padding(.top, proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    ZStack {
                        Theme.canvas
                        WorkingGlow(progress: 0.15, breathes: false, strength: 0.75, riseDuration: 0.6)
                    }
                }
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: docked ? BandFloor.lip : 0,
                                                  bottomTrailingRadius: docked ? BandFloor.lip : 0))
                .overlay(alignment: .bottom) {
                    if docked { CardEdgeLip(radius: BandFloor.lip).frame(height: BandFloor.lip) }
                }
                .padding(.bottom, foot)
                .background { if docked { BandGround(color: nil) } }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    private func content(width: CGFloat) -> some View {
        VStack(spacing: 22) {
            if sideways {
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                EclipseMark()
                    .fill(Theme.ink, style: FillStyle(eoFill: true))
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            if !pins.isEmpty { pinned(width: width) }
            screens(width: width)
        }
        .frame(maxWidth: .infinity)
    }

    /// Centred as a row, so three pins sit in the middle, not hard against one side.
    private func pinned(width: CGFloat) -> some View {
        let cell = (width - 2 * (Theme.gutter + 4)) / CGFloat(Self.perRow)
        let rows = stride(from: 0, to: pins.count, by: Self.perRow).map { Array(pins[$0..<min($0 + Self.perRow, pins.count)]) }
        return VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(rows[index]) { pin in
                        let name = pin.title.isEmpty ? pin.host : pin.title
                        Button { browser.open(pin) } label: {
                            PinTile(pin: pin).frame(width: cell)
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityLabel(name)
                        .contextMenu {
                            Section(name) {
                                Button("Unpin", role: .destructive) { browser.unpin(pin) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Your own screens, each under its own name.
    private func screens(width: CGFloat) -> some View {
        let left = todos.filter(\.isDueNow).count
        return HStack(spacing: 0) {
            screen("Today", .today, .today)
            screen("News", .news, .feed)
            screen("Saved", .readLater, .readLater)
            screen("To-do", .todo, .todos, count: left)
        }
        .frame(width: width - 2 * (Theme.gutter + 4))
    }

    private func screen(_ name: String, _ glyph: Glyph.Kind, _ panel: BrowserModel.Panel, count: Int = 0) -> some View {
        Button { browser.panel = panel } label: {
            VStack(spacing: 6) {
                if count > 0 {
                    CountedGlyph(glyph: glyph, count: count, size: 28)
                } else {
                    Glyph(glyph, size: 24)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 28, height: 28)
                }
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.78))
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(count > 0 ? "\(name), \(count) left for today" : name)
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
                  let (data, response) = try? await URLSession.quick.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { continue }
            cache.setObject(image, forKey: host as NSString)
            return image
        }
        missing.insert(host)
        return nil
    }
}
