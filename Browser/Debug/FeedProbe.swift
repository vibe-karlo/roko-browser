#if DEBUG
import Foundation

/// `-findProbe site,site`: how each site would be followed, with what it gives,
/// in the app's own WebKit, in a Debug build. Also `-searchProbe topic,topic`, and
/// `-readProbe address,address`: what Readability finds there, and its links. And
/// `-backgroundProbe`: what iOS's wake-up runs, timed, as simulators never wake an app.
/// `-mailProbe id,id`: a kept mail's original read again, with long numbers hidden.
/// `-compareProbe count`: the first events in the feed, compared as the screen would.
enum FeedProbe {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        func list(_ name: String) -> [String] {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return [] }
            return arguments[index + 1].split(separator: ",").map(String.init)
        }
        let sites = list("-findProbe"), topics = list("-searchProbe"), pages = list("-readProbe")
        let background = arguments.contains("-backgroundProbe")
        let mails = list("-mailProbe")
        let comparisons = list("-compareProbe").first.flatMap { Int($0) } ?? 0
        guard !sites.isEmpty || !topics.isEmpty || !pages.isEmpty || !mails.isEmpty || background || comparisons > 0 else { return }
        Task {
            if comparisons > 0 {
                await FeedStore.shared.opened()
                let groups = FeedStore.shared.blocks.compactMap { block -> [NewsStory]? in
                    switch block {
                    case .lead(.group(let stories)), .row(.group(let stories)): stories.map(\.story)
                    default: nil
                    }
                }
                for group in groups.prefix(comparisons) {
                    let model = DigestModel(comparing: group)
                    model.start()
                    while model.phase != .done, !model.phase.isFailure { try? await Task.sleep(for: .seconds(1)) }
                    print("COMPARE \(group.count) stories, \(model.engine): \(StoryGroups.title(of: group))\n\(model.phase.isFailure ? "FAILED \(model.phase)" : model.text)\nEND")
                }
            }
            for id in mails {
                guard let link = URL(string: "roko-mail://mail/\(id)"), let html = Newsletters.original(of: link) else { continue }
                let read = await RenderedPage.readable(html: html)
                print("MAIL \(id): \(read?.text.count ?? -1) characters, \(read?.links.count ?? 0) links")
                for line in (read?.text ?? "").components(separatedBy: "\n") where !line.isEmpty {
                    print("   | \(line.prefix(90).replacing(/\d{5,}/, with: "#####"))")
                }
                for link in read?.links.prefix(6) ?? [] { print("   LINK \(link.words.prefix(40)) -> \(link.url.host() ?? "")") }
            }
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
                    print("      PICTURE feed \(story.image?.absoluteString.suffix(50) ?? "none"), page \(await WebResearcher.shareImage(of: story.link)?.absoluteString.suffix(50) ?? "none")")
                    for link in (story.links ?? []).prefix(3) {
                        print("      LINK \(link.words.prefix(40)) -> \(link.url.absoluteString.prefix(60)) in text: \(story.content?.contains(link.block ?? "\u{0}") == true)")
                    }
                }
            }
            for topic in topics {
                let stories = await SiteRoutes.search(topic)
                print("SEARCH \(topic): \(stories.count) stories, \(Set(stories.map(\.host)).count) sites")
                let pool = await TodayNews.stories(of: TodayNews.topicPool, keepingBodies: false).values.flatMap { $0 }
                let found = await TodayNews.about(topic, in: pool + stories, count: 20)
                print("TOPIC \(topic): \(found.count), model \(AppleModels.onDeviceAvailable)")
                for story in found { print("   TOPIC \(story.host): \(story.title.prefix(80))") }
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
