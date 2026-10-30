import QuickLook
import UIKit
import WebKit

/// Files from pages, kept in roko's Downloads folder (also in the Files app,
/// under On My iPhone → roko). A download carries on for as long as iOS lets
/// roko run in the background; if it's stopped there, or the connection drops,
/// it picks up where it stopped once roko is back, rather than starting over.
@MainActor
@Observable
final class Downloads: NSObject {
    static let shared = Downloads()

    struct Item: Identifiable, Codable, Equatable {
        enum State: String, Codable { case running, paused, done, failed }

        let id: UUID
        var name: String
        /// Where it came from.
        var source: URL?
        var state: State
        var received: Int64 = 0
        var total: Int64 = 0
        var startedAt: Date
        /// For picking up a paused or interrupted file.
        var hasResumeData = false

        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }

    private(set) var items: [Item] = []
    /// A file that just finished, offered above the bar.
    private(set) var finished: Item?
    @ObservationIgnored private var finishedTask: Task<Void, Never>?

    @ObservationIgnored private var running: [UUID: WKDownload] = [:]
    @ObservationIgnored private var ids: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var progress: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid
    /// Stopped by roko going to the background, not by you: resumed on return.
    @ObservationIgnored private var interrupted = Set<UUID>()
    /// The tabs' web views (set by BrowserModel): a download resumes in one.
    @ObservationIgnored var liveWebViews: () -> [WKWebView] = { [] }
    /// Something to resume downloads with when no tab is live.
    @ObservationIgnored private var spareWebView: WKWebView?

    static let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The list itself and resume data live out of the Files app's sight.
    private static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var listFile: URL { support.appendingPathComponent("list.json") }
    private static func resumeFile(_ id: UUID) -> URL { support.appendingPathComponent("\(id.uuidString).resume") }

    func file(for item: Item) -> URL { Self.folder.appendingPathComponent(item.name) }

    var activeCount: Int { items.filter { $0.state == .running }.count }

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.listFile),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            // Running when roko was closed: picked up from where it stopped, if it can be.
            items = saved.map { item in
                var item = item
                if item.state == .running {
                    item.state = item.hasResumeData ? .paused : .failed
                    if item.hasResumeData { interrupted.insert(item.id) }
                }
                return item
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Downloads.shared.keepGoingInBackground() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Downloads.shared.cameBack() }
        }
    }

    // MARK: From pages

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = Item(id: UUID(), name: "Download", source: download.originalRequest?.url, state: .running,
                        startedAt: .now)
        items.insert(item, at: 0)
        start(download, as: item.id)
    }

    private func start(_ download: WKDownload, as id: UUID) {
        running[id] = download
        ids[ObjectIdentifier(download)] = id
        progress[id] = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.update(id) { $0.received = received; $0.total = max(total, 0) } }
        }
        save()
    }

    // MARK: Your controls

    func pause(_ item: Item) {
        guard let download = running[item.id] else { return }
        // Paused first, so the cancel's own failure report isn't taken for a dropped connection.
        update(item.id) { $0.state = .paused }
        Task {
            let data = await download.cancel()
            finish(item.id)
            keep(data, for: item.id)
            update(item.id) { $0.state = .paused }
        }
    }

    func resume(_ item: Item) {
        interrupted.remove(item.id)
        guard let data = try? Data(contentsOf: Self.resumeFile(item.id)) else {
            // Nothing to pick up from: from the start, if we know where it came from.
            if let source = item.source {
                remove(item)
                Task { await startOver(source) }
            }
            return
        }
        update(item.id) { $0.state = .running }
        Task {
            let download = await webViewForResuming().resumeDownload(fromResumeData: data)
            download.delegate = self
            start(download, as: item.id)
        }
    }

    /// A file that failed: from where it stopped if it can, otherwise from the start.
    func retry(_ item: Item) {
        resume(item)
    }

    private func startOver(_ source: URL) async {
        let download = await webViewForResuming().startDownload(using: URLRequest(url: source))
        track(download)
    }

    func remove(_ item: Item) {
        if let download = running[item.id] { download.cancel(nil) }
        finish(item.id)
        if item.state == .done { try? FileManager.default.removeItem(at: file(for: item)) }
        try? FileManager.default.removeItem(at: Self.resumeFile(item.id))
        items.removeAll { $0.id == item.id }
        if finished?.id == item.id { finished = nil }
        save()
    }

    /// Finished ones off the list; their files stay in Files.
    func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .failed }
        save()
    }

    func dismissFinished() {
        finished = nil
        finishedTask?.cancel()
    }

    // MARK: Opening

    /// A pass goes to Wallet; anything else opens in Quick Look, where it can
    /// be shared or saved elsewhere.
    func open(_ item: Item) {
        dismissFinished()
        let url = file(for: item)
        if url.pathExtension.lowercased() == "pkpass" {
            PageDialogs.open(downloaded: url)
            return
        }
        let preview = QLPreviewController()
        let source = PreviewSource(url: url)
        preview.dataSource = source
        objc_setAssociatedObject(preview, &PreviewSource.key, source, .OBJC_ASSOCIATION_RETAIN)
        PageDialogs.top?.present(preview, animated: true)
    }

    // MARK: Background

    /// Keeps going for as long as iOS gives roko; just before it's stopped,
    /// each file keeps what it has so far.
    private func keepGoingInBackground() {
        guard !running.isEmpty, background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Downloads") {
            MainActor.assumeIsolated { Downloads.shared.stopForNow() }
        }
    }

    private func stopForNow() {
        let downloads = running
        guard !downloads.isEmpty else { return endBackground() }
        let group = DispatchGroup()
        for (id, download) in downloads {
            group.enter()
            interrupted.insert(id)
            update(id) { $0.state = .paused }
            download.cancel { data in
                MainActor.assumeIsolated {
                    Downloads.shared.finish(id)
                    Downloads.shared.keep(data, for: id)
                    Downloads.shared.update(id) { $0.state = .paused }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { Downloads.shared.endBackground() } }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func cameBack() {
        endBackground()
        for item in items where interrupted.contains(item.id) && item.state == .paused { resume(item) }
    }

    // MARK: Bookkeeping

    private func webViewForResuming() async -> WKWebView {
        if let webView = liveWebViews().first { return webView }
        if let spareWebView { return spareWebView }
        let webView = WebViewFactory.makeOffscreen()
        spareWebView = webView
        return webView
    }

    private func keep(_ data: Data?, for id: UUID) {
        if let data {
            try? data.write(to: Self.resumeFile(id), options: .atomic)
        }
        update(id) { $0.hasResumeData = data != nil }
    }

    private func finish(_ id: UUID) {
        if let download = running.removeValue(forKey: id) { ids.removeValue(forKey: ObjectIdentifier(download)) }
        progress.removeValue(forKey: id)
        if running.isEmpty, background != .invalid, interrupted.isEmpty { endBackground() }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        let stateChanged = item.state != items[index].state
        items[index] = item
        // Progress alone isn't worth a write; the next state change saves it.
        if stateChanged { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.listFile, options: .atomic)
    }

    /// A free name in the folder: "report.pdf", then "report 2.pdf".
    private func freeName(_ suggested: String) -> String {
        let name = suggested.isEmpty ? "Download" : suggested.replacingOccurrences(of: "/", with: "-")
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, number = 2
        while FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(candidate).path)
                || items.contains(where: { $0.name == candidate && $0.state != .done && $0.state != .failed }) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }
}

extension Downloads: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard let id = ids[ObjectIdentifier(download)] else { return nil }
        let name = freeName(suggestedFilename)
        update(id) {
            $0.name = name
            $0.total = max(response.expectedContentLength, 0)
        }
        save()
        return Self.folder.appendingPathComponent(name)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = ids[ObjectIdentifier(download)] else { return }
        finish(id)
        try? FileManager.default.removeItem(at: Self.resumeFile(id))
        update(id) {
            $0.state = .done
            $0.hasResumeData = false
            if $0.total > 0 { $0.received = $0.total }
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        // A boarding pass or ticket goes straight to Wallet, as in Safari.
        if file(for: item).pathExtension.lowercased() == "pkpass" {
            PageDialogs.open(downloaded: file(for: item))
            return
        }
        finished = item
        finishedTask?.cancel()
        finishedTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { finished = nil }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = ids[ObjectIdentifier(download)] else { return }
        finish(id)
        // Already paused by you or by the background: that state stands.
        guard items.first(where: { $0.id == id })?.state == .running else { return }
        keep(resumeData, for: id)
        // The connection dropped: picked up again when roko next comes back.
        if resumeData != nil { interrupted.insert(id) }
        update(id) { $0.state = resumeData != nil ? .paused : .failed }
    }
}

/// Quick Look's one file.
private final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    nonisolated(unsafe) static var key = 0
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}
