import Foundation

/// Sites Browse for Me never reads or cites: expired domains bought to host
/// pages of affiliate links ("15 Best Noise Cancelling Headphones" on what was
/// a film's fan site or a couple's wedding blog). They rank for buying
/// questions and say nothing a real reviewer doesn't. Each was seen among the
/// sources of a real answer; add more the same way, by the host alone.
///
/// Claude's search is told not to use them (its `blocked_domains`), and both
/// engines drop them from what they show, in case one slips through anyway.
nonisolated enum JunkSites {
    static let domains: [String] = [
        "bygrinstow.com",
        "comstock-interactivedata.com",
        "lynnbarsigianphotography.com",
        "modimalabs.com",
        "orchyd.com",
        "requiemforadream.com",
        "sarahleeandjohnny.com",
        "themplsegotist.com",
    ]

    private static let set = Set(domains)

    /// The host or any site it's part of is on the list: "www.orchyd.com" is.
    static func contains(_ url: URL) -> Bool {
        var parts = url.displayHost.lowercased().split(separator: ".")
        while parts.count >= 2 {
            if set.contains(parts.joined(separator: ".")) { return true }
            parts.removeFirst()
        }
        return false
    }
}
