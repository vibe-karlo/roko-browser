import Foundation

/// The most visited sites in this phone's country and in the world, to suggest
/// while typing an address. From Chrome's public report, filtered and ordered by
/// Scripts/build_top_sites.py. One file holds every country, each compressed on
/// its own: only this phone's and the world's are ever inflated, the first time
/// the bar is typed in, and that's a few hundred prefix checks per keystroke.
/// No network: nothing typed leaves the phone for these.
enum TopSites {
    /// Hosts that start with what was typed, most visited first.
    static func matching(_ needle: String, limit: Int) -> [String] {
        let bare = needle.hasPrefix("www.") ? String(needle.dropFirst(4)) : needle
        guard limit > 0, !bare.isEmpty else { return [] }
        var found: [String] = []
        for host in hosts where host.hasPrefix(bare) {
            found.append(host)
            if found.count == limit { break }
        }
        return found
    }

    /// This country's own version of a big shop, if it has one: amazon.de for
    /// amazon.com in Germany.
    static func ownVersion(of host: String) -> String? {
        guard let name = host.split(separator: ".").first, let ending else { return nil }
        return hosts.first { $0.hasPrefix(name + ".") && $0.hasSuffix("." + ending) }
    }

    /// The domain ending this phone's country uses.
    private static let ending: String? = Locale.current.region.map { region in
        let code = region.identifier.lowercased()
        return code == "gb" ? "uk" : code
    }

    /// This country's, then the world's.
    private static let hosts: [String] = {
        guard let url = Bundle.main.url(forResource: "top-sites", withExtension: "bin"),
              let file = try? Data(contentsOf: url, options: .mappedIfSafe),
              let newline = file.firstIndex(of: 10) else { return [] }
        var slices: [Substring: (offset: Int, length: Int)] = [:]
        for entry in String(decoding: file[..<newline], as: UTF8.self).split(separator: " ") {
            let parts = entry.split(separator: ":")
            guard parts.count == 3, let offset = Int(parts[1]), let length = Int(parts[2]) else { continue }
            slices[parts[0]] = (offset, length)
        }
        let code = Locale.current.region?.identifier.lowercased() ?? ""
        var seen = Set<String>()
        return [code, "zz"].flatMap { list -> [String] in
            guard let slice = slices[Substring(list)] else { return [] }
            let start = newline + 1 + slice.offset
            let packed = file.subdata(in: start..<(start + slice.length)) as NSData
            guard let text = try? packed.decompressed(using: .zlib) as Data else { return [] }
            return String(decoding: text, as: UTF8.self).split(separator: "\n").map(String.init)
        }.filter { seen.insert($0).inserted }
    }()
}
