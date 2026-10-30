import AVFoundation
import UIKit
import WebKit

/// YouTube as sound while roko is in the background or the iPhone is locked.
/// Any app playing sound needs the audio background mode (project.yml) and a
/// playback audio session, which also keeps a page's sound on with the
/// Ring/Silent switch at silent. Then two things stand in the way:
/// - YouTube pauses itself when its page goes out of view. background-play.js
///   tells it the page is still in view.
/// - WebKit pauses every video with sound as an app leaves the screen (sound
///   alone it leaves playing). A play asked for just after is allowed, so roko
///   notes what was playing as it leaves and asks it to play on.
enum BackgroundPlay {
    static let script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "background-play", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // In the page's own world: it's YouTube's script that asks whether it's in view.
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }()

    /// At launch, and after voice input has had the session for recording.
    static func prepareSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    private static var leaving: [WKWebView] = []

    /// `webViews`: every live tab's.
    static func watch(_ webViews: @escaping @MainActor @Sendable () -> [WKWebView]) {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { noteLeaving(webViews()) }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { playOn() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { leaving = [] }
        }
    }

    /// Before WebKit pauses anything: which YouTube pages are playing.
    private static func noteLeaving(_ webViews: [WKWebView]) {
        leaving = []
        for webView in webViews where isYouTube(webView.url) {
            webView.evaluateJavaScript("window.__rokoLeaving?.() === true", in: nil, in: .page) { result in
                if case .success(let playing as Bool) = result, playing { leaving.append(webView) }
            }
        }
    }

    /// Once WebKit has paused them. The moment's wait is for WebKit, which
    /// pauses on the same notification; the background task keeps roko awake
    /// until the sound is back and holds it there.
    private static func playOn() {
        guard !leaving.isEmpty else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Background play")
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            for webView in leaving {
                _ = try? await webView.evaluateJavaScript("window.__rokoPlayOn?.()", contentWorld: .page)
            }
            leaving = []
            try? await Task.sleep(for: .seconds(2))
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private static func isYouTube(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}
