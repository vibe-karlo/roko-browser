import XCTest
import UIKit

// One browser opening one page, recorded from the phone itself: small grey frames and the
// phone's network counters as fast as they come, then full screenshots of where it ended up.
struct Item: Codable { let id, b, bundle, url: String; let seconds: Double; let scrolls: Int?; let dump: Bool? }

func counters() -> (UInt64, UInt64, UInt64, UInt64) {
    var wifiIn: UInt64 = 0, wifiOut: UInt64 = 0, cellIn: UInt64 = 0, cellOut: UInt64 = 0
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return (0, 0, 0, 0) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let c = cursor {
        if c.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK), let raw = c.pointee.ifa_data {
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: c.pointee.ifa_name)
            if name == "en0" { wifiIn += UInt64(d.ifi_ibytes); wifiOut += UInt64(d.ifi_obytes) }
            if name.hasPrefix("pdp_ip") { cellIn += UInt64(d.ifi_ibytes); cellOut += UInt64(d.ifi_obytes) }
        }
        cursor = c.pointee.ifa_next
    }
    freeifaddrs(first)
    return (wifiIn, wifiOut, cellIn, cellOut)
}

let thumbW = 100, thumbH = 218
func grey(_ image: UIImage) -> Data? {
    guard let cg = image.cgImage else { return nil }
    var bytes = [UInt8](repeating: 0, count: thumbW * thumbH)
    let ok: Bool = bytes.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: thumbW, height: thumbH, bitsPerComponent: 8, bytesPerRow: thumbW, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        return true
    }
    return ok ? Data(bytes) : nil
}

final class RealBench: XCTestCase {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func log(_ s: String) {
        let line = Data((s + "\n").utf8), url = docs.appendingPathComponent("log.jsonl")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); h.closeFile() } else { try? line.write(to: url) }
    }

    func save(_ image: UIImage, _ name: String, quality: CGFloat = 0.72) {
        try? image.jpegData(compressionQuality: quality)?.write(to: docs.appendingPathComponent(name))
    }

    func testRun() throws {
        continueAfterFailure = true
        // The Mac has pulled everything and pushed a new plan: start clean.
        if FileManager.default.fileExists(atPath: docs.appendingPathComponent("clear").path) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? [] where name != "plan.json" {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
            }
        }
        let plan = try JSONDecoder().decode([Item].self, from: Data(contentsOf: docs.appendingPathComponent("plan.json")))
        let progress = docs.appendingPathComponent("progress.txt")
        var done = Set(((try? String(contentsOf: progress)) ?? "").split(separator: "\n").map(String.init))
        for item in plan where !done.contains(item.id) {
            if FileManager.default.fileExists(atPath: docs.appendingPathComponent("stop").path) { return }
            var blocked = false
            autoreleasepool { blocked = run(item) }
            if blocked { try? item.id.write(to: docs.appendingPathComponent("blocked.txt"), atomically: true, encoding: .utf8); return }
            done.insert(item.id)
            try? done.sorted().joined(separator: "\n").write(to: progress, atomically: true, encoding: .utf8)
        }
    }

    func run(_ item: Item) -> Bool {
        let app = XCUIApplication(bundleIdentifier: item.bundle)
        let started = Date()
        app.terminate()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.5)
        let frames = docs.appendingPathComponent(item.id + ".frames")
        FileManager.default.createFile(atPath: frames.path, contents: nil)
        let out = try! FileHandle(forWritingTo: frames)
        let t0 = Date()
        let before = counters()
        let url = URL(string: item.url)!
        // XCUIApplication has to stay on the main thread, so the frames come from a second one.
        var count = 0, last: UIImage?
        let finished = DispatchSemaphore(value: 0)
        let seconds = item.seconds
        Thread.detachNewThread {
            while Date().timeIntervalSince(t0) < seconds {
                autoreleasepool {
                    let shot = XCUIScreen.main.screenshot().image
                    let now = Date().timeIntervalSince(t0), c = counters()
                    guard let g = grey(shot) else { return }
                    var head = [now, Double(c.0), Double(c.1), Double(c.2), Double(c.3)]
                    head.withUnsafeMutableBytes { out.write(Data($0)) }
                    out.write(g)
                    count += 1
                    last = shot
                }
            }
            out.closeFile()
            finished.signal()
        }
        let openedAt = Date().timeIntervalSince(t0)
        app.open(url)
        let openDone = Date().timeIntervalSince(t0)
        while finished.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let after = counters()
        if let last { save(last, item.id + ".jpg") }
        // Screen Time's shield isn't a result: stop, so this run happens again once it's lifted.
        let shield = NSPredicate(format: "label CONTAINS 'Time Allowance' OR label CONTAINS 'scheduled time' OR identifier == 'ignore-limit-button'")
        let v1 = app.descendants(matching: .any).matching(shield).firstMatch.exists
        let v2 = app.buttons["ignore-limit-button"].exists
        log("{\"id\":\"\(item.id)\",\"shieldAny\":\(v1),\"shieldButton\":\(v2)}")
        if v1 || v2 {
            log("{\"id\":\"\(item.id)\",\"blocked\":true}")
            try? FileManager.default.removeItem(at: frames)
            return true
        }
        if item.dump == true {
            let tree = Date()
            let text = app.debugDescription
            try? text.write(to: docs.appendingPathComponent(item.id + ".tree.txt"), atomically: true, encoding: .utf8)
            log("{\"id\":\"\(item.id)\",\"treeSeconds\":\(Date().timeIntervalSince(tree))}")
        }
        for n in 0..<(item.scrolls ?? 0) {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.5)
            save(XCUIScreen.main.screenshot().image, item.id + ".s\(n + 1).jpg", quality: 0.6)
        }
        let info: [String: Any] = ["id": item.id, "b": item.b, "url": item.url, "at": started.timeIntervalSince1970, "frames": count, "fps": Double(count) / item.seconds, "openedAt": openedAt, "openDone": openDone, "inWifi": after.0 &- before.0, "outWifi": after.1 &- before.1, "inCell": after.2 &- before.2, "outCell": after.3 &- before.3, "thermal": ProcessInfo.processInfo.thermalState.rawValue, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "state": app.state.rawValue]
        log(String(data: try! JSONSerialization.data(withJSONObject: info), encoding: .utf8)!)
        return false
    }
}
