// Compiles each generated list with WebKit, exactly as the app does on launch:
// its plain hosts (<name>-hosts.txt) made into block rules, then <name>.json.
// Run on the Mac after build_blocklists.py:  swift Scripts/verify_blocklists.swift

import Foundation
import WebKit

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Browser/Resources/Blocklists")
let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("blocklist-verify-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
let store = WKContentRuleListStore(url: storeURL)!

/// The same as ContentBlocker.rules(json:hosts:) in the app.
func rules(_ name: String) throws -> String {
    let rest = try String(contentsOf: directory.appendingPathComponent("\(name).json"), encoding: .utf8)
    guard let text = try? String(contentsOf: directory.appendingPathComponent("\(name)-hosts.txt"), encoding: .utf8) else { return rest }
    let hosts = text.split(separator: "\n").map {
        #"{"trigger":{"url-filter":"^[^:]+://+([^/]+\\.)?"# + $0.replacingOccurrences(of: ".", with: #"\\."#)
            + #"[/:?&=]"},"action":{"type":"block"}}"#
    }
    let others = rest.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
    return "[" + hosts.joined(separator: ",") + (others.first == "]" || hosts.isEmpty ? "" : ",") + others
}

var failed = false
for name in ["ads", "privacy", "cookies", "popups"] {
    let start = Date()
    do {
        _ = try await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: try rules(name))
        print(String(format: "%@: compiled in %.2fs", name, Date().timeIntervalSince(start)))
    } catch {
        failed = true
        print("\(name): FAILED - \(error)")
    }
}
try? FileManager.default.removeItem(at: storeURL)
exit(failed ? 1 : 0)
