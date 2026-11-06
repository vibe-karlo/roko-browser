#if DEBUG
import Foundation

/// `-findProbe site,site`: how each site would be followed, with what it gives,
/// in the app's own WebKit, in a Debug build. Also `-searchProbe topic,topic`, and
/// `-readProbe address,address`: what Readability finds there, and its links. And
/// `-backgroundProbe`: what iOS's wake-up runs, timed, as simulators never wake an app.
enum FeedProbe {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        func list(_ name: String) -> [String] {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return [] }
            return arguments[index + 1].split(separator: ",").map(String.init)
        }
        let sites = list("-findProbe"), topics = list("-searchProbe"), pages = list("-readProbe")
        let background = arguments.contains("-backgroundProbe")
        guard !sites.isEmpty || !topics.isEmpty || !pages.isEmpty || background else { return }
        Task {
            if background {
                let before = FeedStore.shared.unreadCount, started = Date.now
                await FeedStore.shared.refresh(inBackground: true)
                print("BACKGROUND \(Date.now.timeIntervalSince(started)) seconds, to read \(before) -> \(FeedStore.shared.unreadCount), \(NewsSite.chosen.count) sites, \(NewsTopics.chosen.count) topics")
            }
            for site in sites {
                guard let found = await TodayNews.find(site) else {
                    print("FIND \(site): nothing")
                    continue
                }
                let route = found.feed != nil ? "feed" : found.sitemap != nil ? "sitemap" : "page"
                let stories = await TodayNews.stories(of: found, keepingBodies: true)
                print("FIND \(site): \(route) \(found.feed?.absoluteString ?? found.sitemap?.absoluteString ?? ""), \(stories.count) stories")
                for story in stories.prefix(3) {
                    print("   \(story.title.prefix(70)) | \(story.published?.formatted(.iso8601) ?? "no date") | \(story.link.absoluteString.suffix(50))")
                    for link in (story.links ?? []).prefix(3) {
                        print("      LINK \(link.words.prefix(40)) -> \(link.url.absoluteString.prefix(60)) in text: \(story.content?.contains(link.block ?? "\u{0}") == true)")
                    }
                }
            }
            for topic in topics {
                let stories = await SiteRoutes.search(topic)
                print("SEARCH \(topic): \(stories.count) stories, \(Set(stories.map(\.host)).count) sites")
                for story in stories.prefix(3) { print("   \(story.host): \(story.title.prefix(70))") }
            }
            for address in pages {
                guard let url = URL(string: address), let page = await RenderedPage.readable(of: url) else {
                    print("READ \(address): nothing")
                    continue
                }
                let inText = page.links.filter { page.text.contains($0.block ?? "\u{0}") }.count
                print("READ \(address): \(page.text.count) characters, \(page.links.count) links, \(inText) in their paragraph")
                for link in page.links.prefix(5) { print("      LINK \(link.words.prefix(40)) -> \(link.url.absoluteString.prefix(70))") }
            }
            print("PROBE done")
        }
    }
}
#endif
