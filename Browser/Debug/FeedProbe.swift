#if DEBUG
import Foundation

/// `-findProbe site,site`: how each site would be followed, with what it gives,
/// in the app's own WebKit, in a Debug build. Also `-searchProbe topic,topic`, and
/// `-readProbe address,address`: what Readability finds there, and its links.
enum FeedProbe {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        func list(_ name: String) -> [String] {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return [] }
            return arguments[index + 1].split(separator: ",").map(String.init)
        }
        let sites = list("-findProbe"), topics = list("-searchProbe"), pages = list("-readProbe")
        guard !sites.isEmpty || !topics.isEmpty || !pages.isEmpty else { return }
        Task {
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
