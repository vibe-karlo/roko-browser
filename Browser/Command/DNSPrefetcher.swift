import Foundation

/// Looks up a site's address while you're still choosing it in the command
/// bar, so by the time you press Go the answer is already in the system DNS
/// cache, which WebKit's network process shares. Saves a round trip per page.
enum DNSPrefetcher {
    private static var recent: [String: Date] = [:]

    static func warm(_ host: String?) {
        guard let host, !host.isEmpty else { return }
        if let last = recent[host], Date.now.timeIntervalSince(last) < 60 { return }
        recent[host] = .now
        Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, "443", &hints, &result) == 0 {
                freeaddrinfo(result)
            }
        }
    }
}
