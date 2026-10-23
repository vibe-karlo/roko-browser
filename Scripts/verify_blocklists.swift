// Compiles each generated list with WebKit, exactly as the app does on launch.
// Run on the Mac after build_blocklists.py:  swift Scripts/verify_blocklists.swift

import Foundation
import WebKit

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Browser/Resources/Blocklists")
let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("blocklist-verify-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
let store = WKContentRuleListStore(url: storeURL)!

var failed = false
for name in ["ads", "privacy", "cookies", "popups"] {
    let json = try String(contentsOf: directory.appendingPathComponent("\(name).json"), encoding: .utf8)
    let start = Date()
    do {
        _ = try await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json)
        let first = Date().timeIntervalSince(start)
        let lookupStart = Date()
        _ = try await store.contentRuleList(forIdentifier: name)
        let lookup = Date().timeIntervalSince(lookupStart)
        print(String(format: "%@: compiled in %.2fs, cached lookup %.0fms", name, first, lookup * 1000))
    } catch {
        failed = true
        print("\(name): FAILED - \(error)")
    }
}
try? FileManager.default.removeItem(at: storeURL)
exit(failed ? 1 : 0)
