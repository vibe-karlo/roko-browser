import UIKit

/// Pages that have an app on this iPhone: YouTube, Instagram, Spotify and the
/// like. iOS won't say which apps claim which links without opening them, so
/// roko asks whether the app is installed by its URL scheme (each one is
/// listed under LSApplicationQueriesSchemes, as iOS requires), then opens the
/// page itself in it as a universal link.
enum AppLinks {
    /// Settings → Tabs → Open links in apps.
    enum Mode: String, CaseIterable, Identifiable {
        /// A small offer above the bar on a page whose app you have.
        case offer
        /// A link you tap to such a page opens in the app, as in Safari.
        case always
        /// Pages stay in roko; nothing is offered.
        case never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .offer: "Offer"
            case .always: "Always"
            case .never: "Off"
            }
        }

        static let key = "links.apps"

        static var current: Mode {
            UserDefaults.standard.string(forKey: key).flatMap(Mode.init(rawValue:)) ?? .offer
        }
    }

    struct App: Equatable {
        let name: String
        let scheme: String
    }

    /// By site; a site's subdomains (m., www., music.) count as the site,
    /// unless they're listed themselves.
    private static let apps: [String: App] = [
        "youtube.com": App(name: "YouTube", scheme: "youtube"),
        "youtu.be": App(name: "YouTube", scheme: "youtube"),
        "music.youtube.com": App(name: "YouTube Music", scheme: "youtubemusic"),
        "instagram.com": App(name: "Instagram", scheme: "instagram"),
        "facebook.com": App(name: "Facebook", scheme: "fb"),
        "threads.net": App(name: "Threads", scheme: "barcelona"),
        "threads.com": App(name: "Threads", scheme: "barcelona"),
        "x.com": App(name: "X", scheme: "twitter"),
        "twitter.com": App(name: "X", scheme: "twitter"),
        "reddit.com": App(name: "Reddit", scheme: "reddit"),
        "tiktok.com": App(name: "TikTok", scheme: "tiktok"),
        "linkedin.com": App(name: "LinkedIn", scheme: "linkedin"),
        "pinterest.com": App(name: "Pinterest", scheme: "pinterest"),
        "open.spotify.com": App(name: "Spotify", scheme: "spotify"),
        "soundcloud.com": App(name: "SoundCloud", scheme: "soundcloud"),
        "twitch.tv": App(name: "Twitch", scheme: "twitch"),
        "netflix.com": App(name: "Netflix", scheme: "nflx"),
        "medium.com": App(name: "Medium", scheme: "medium"),
        "github.com": App(name: "GitHub", scheme: "github"),
        "notion.so": App(name: "Notion", scheme: "notion"),
        "figma.com": App(name: "Figma", scheme: "figma"),
        "discord.com": App(name: "Discord", scheme: "discord"),
        "t.me": App(name: "Telegram", scheme: "tg"),
        "wa.me": App(name: "WhatsApp", scheme: "whatsapp"),
        "zoom.us": App(name: "Zoom", scheme: "zoomus"),
        "airbnb.com": App(name: "Airbnb", scheme: "airbnb"),
        "booking.com": App(name: "Booking.com", scheme: "booking"),
        "tripadvisor.com": App(name: "Tripadvisor", scheme: "tripadvisor"),
        "uber.com": App(name: "Uber", scheme: "uber"),
        "wolt.com": App(name: "Wolt", scheme: "wolt"),
        "ebay.com": App(name: "eBay", scheme: "ebay"),
        "etsy.com": App(name: "Etsy", scheme: "etsy"),
        "amazon.com": App(name: "Amazon", scheme: "com.amazon.mobile.shopping"),
        "maps.google.com": App(name: "Google Maps", scheme: "comgooglemaps"),
    ]

    /// The app for this page, if it's on this iPhone.
    @MainActor
    static func installedApp(for url: URL) -> App? {
        guard url.scheme == "https" || url.scheme == "http",
              var host = url.host()?.lowercased() else { return nil }
        // Google Maps lives under google.com/maps as well.
        if host.hasSuffix("google.com"), url.path().hasPrefix("/maps") { host = "maps.google.com" }
        var candidate = host
        var app: App?
        while app == nil, candidate.contains(".") {
            app = apps[candidate]
            candidate = String(candidate.drop { $0 != "." }.dropFirst())
        }
        guard let app, let probe = URL(string: "\(app.scheme)://"),
              UIApplication.shared.canOpenURL(probe) else { return nil }
        return app
    }

    /// Opens the page in its app. False when the app doesn't take this page
    /// (not every address on a site is one its app opens).
    @MainActor
    static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
    }

    /// Same site, so moving around inside one in roko doesn't throw you into its app.
    static func sameSite(_ a: URL?, _ b: URL) -> Bool {
        guard let first = a?.host()?.lowercased(), let second = b.host()?.lowercased() else { return false }
        func base(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".") }
        return base(first) == base(second)
    }
}
