#if DEBUG
import Foundation

/// `-findProbe site,site`: how each site would be followed, with what it gives,
/// in the app's own WebKit, in a Debug build. Also `-searchProbe topic,topic`.
enum FeedProbe {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        func list(_ name: String) -> [String] {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return [] }
            return arguments[index + 1].split(separator: ",").map(String.init)
        }
        let sites = list("-findProbe"), topics = list("-searchProbe")
        guard !sites.isEmpty || !topics.isEmpty else { return }
        Task {
            for site in sites {
                guard let found = await TodayNews.find(site) else {
                    print("FIND \(site): nothing")
                    continue
                }
                let route = found.feed != nil ? "feed" : found.sitemap != nil ? "sitemap" : "page"
                let stories = await TodayNews.stories(of: found)
                print("FIND \(site): \(route) \(found.feed?.absoluteString ?? found.sitemap?.absoluteString ?? ""), \(stories.count) stories")
                for story in stories.prefix(3) {
                    print("   \(story.title.prefix(70)) | \(story.published?.formatted(.iso8601) ?? "no date") | \(story.link.absoluteString.suffix(50))")
                }
            }
            for topic in topics {
                let stories = await SiteRoutes.search(topic)
                print("SEARCH \(topic): \(stories.count) stories, \(Set(stories.map(\.host)).count) sites")
                for story in stories.prefix(3) { print("   \(story.host): \(story.title.prefix(70))") }
            }
            print("PROBE done")
        }
    }
}
#endif
