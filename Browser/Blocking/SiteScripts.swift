import Foundation
import WebKit

/// What a site's page needs changed before it runs, so its own anti-adblock wall never
/// comes up (site-scripts.js). The table is sorted (Scripts/build_scriptlets.py) and only
/// mapped, never parsed, so a site with no rule costs a few comparisons and no memory.
enum SiteScripts {
    private static let table = Bundle.main.url(forResource: "site-scripts", withExtension: "txt")
        .flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }

    private static let engine = Bundle.main.url(forResource: "site-scripts", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// This site's calls as one JSON array, or nil for a site with none.
    static func calls(for host: String?) -> String? {
        guard let host, let table else { return nil }
        let labels = host.lowercased().split(separator: ".")
        var rows: [Substring] = []
        for start in labels.indices.dropLast() {
            let suffix = labels[start...]
            if let row = row(for: suffix.joined(separator: "."), in: table) { rows.append(row) }
            // "name.*": a name under whichever ending, one label or two (co.uk).
            for cut in 1...2 where suffix.count > cut {
                if let row = row(for: suffix.dropLast(cut).joined(separator: ".") + ".*", in: table) { rows.append(row) }
            }
        }
        guard !rows.isEmpty else { return nil }
        return "[" + rows.map { $0.dropFirst().dropLast() }.joined(separator: ",") + "]"
    }

    static func script(calls: String) -> WKUserScript? {
        guard let engine else { return nil }
        return WKUserScript(source: engine.replacingOccurrences(of: "__ROKO_CALLS__", with: calls),
                            injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Binary search of "\nhost\tcalls\n" rows: bytes compare as the build sorted them.
    private static func row(for host: String, in table: Data) -> Substring? {
        let key = Array(host.utf8)
        return table.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Substring? in
            let all = bytes.bindMemory(to: UInt8.self)
            var low = 1, high = all.count
            while low < high {
                var start = (low + high) / 2
                while start > low, all[start - 1] != 10 { start -= 1 }
                var keyEnd = start
                while keyEnd < all.count, all[keyEnd] != 9, all[keyEnd] != 10 { keyEnd += 1 }
                var lineEnd = keyEnd
                while lineEnd < all.count, all[lineEnd] != 10 { lineEnd += 1 }
                var order = 0, i = 0
                while order == 0, i < key.count, start + i < keyEnd {
                    order = Int(key[i]) - Int(all[start + i])
                    i += 1
                }
                if order == 0 { order = key.count - (keyEnd - start) }
                if order == 0 {
                    return Substring(decoding: UnsafeBufferPointer(rebasing: all[(keyEnd + 1)..<lineEnd]), as: UTF8.self)
                }
                if order < 0 { high = start } else { low = lineEnd + 1 }
            }
            return nil
        }
    }
}
