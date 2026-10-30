import Foundation

/// A link as you'd want to hand it on: without the parts that only tell
/// someone where it came from (utm_source, fbclid, Instagram's igsh and the
/// like). Used when you copy or share the page; the page itself keeps its
/// address. Anything that might change what the link opens stays.
enum CleanLink {
    /// Dropped on every site.
    private static let everywhere: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid",
        "ttclid", "li_fat_id", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "igsh", "igshid",
        "s_kwcid", "srsltid", "_gl", "oly_anon_id", "oly_enc_id", "vero_id", "rb_clickid", "wickedid",
        "ref_src", "ref_url",
    ]

    /// Dropped only on these sites, where they mean "shared by" and nothing else.
    private static let bySite: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"],
        "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si", "context"],
        "instagram.com": ["utm_source", "img_index"],
        "x.com": ["s", "t"],
        "twitter.com": ["s", "t"],
        "linkedin.com": ["trk", "trackingId", "lipi", "originalSubdomain", "rcm"],
        "reddit.com": ["share_id", "rdt"],
        "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device", "web_id"],
    ]

    /// Every Amazon store (amazon.com, .de, .co.uk...), besides its pd_rd_ and pf_rd_ ones.
    private static let amazon: Set<String> = ["content-id", "ref_", "_encoding", "psf", "qid", "sr"]

    static func clean(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, !items.isEmpty else { return url }
        let host = parts.host?.lowercased() ?? ""
        let isAmazon = host.hasPrefix("amazon.") || host.contains(".amazon.")
        let site = isAmazon ? amazon : bySite.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { item in
            let name = item.name
            let lower = name.lowercased()
            if lower.hasPrefix("utm_") || everywhere.contains(lower) || site.contains(name) { return false }
            if isAmazon, lower.hasPrefix("pd_rd_") || lower.hasPrefix("pf_rd_") { return false }
            return true
        }
        guard kept.count != items.count else { return url }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }
}
