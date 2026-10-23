import SwiftUI

/// Lays out the Markdown the AI features write as a small page: a title, the
/// gist set large ("> " line), then sections whose topic icon sits in a gutter
/// beside the heading and its lines. While text is still arriving,
/// an orange caret follows the last word, and each new section settles in.
struct MarkdownText: View {
    let markdown: String
    var isStreaming = false

    private struct Section: Identifiable {
        let id: Int
        var topic: String?
        var heading: String?
        var lines: [Line] = []
    }

    private enum Line {
        case bullet(String), paragraph(String)
    }

    private struct Page {
        var title: String?
        var lead: [String] = []
        var sections: [Section] = []
    }

    private var page: Page {
        var page = Page()
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A heading still being written ("#", "##"): wait for its words.
            if line.allSatisfy({ $0 == "#" }) || line == ">" { continue }
            if line.hasPrefix("## ") {
                let (topic, heading) = Self.splitTopic(String(line.dropFirst(3)))
                page.sections.append(Section(id: page.sections.count, topic: topic, heading: heading))
            } else if line.hasPrefix("# ") {
                page.title = String(line.dropFirst(2))
            } else if line.hasPrefix(">") {
                page.lead.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else {
                let item: Line = line.hasPrefix("- ") || line.hasPrefix("* ")
                    ? .bullet(String(line.dropFirst(2))) : .paragraph(line)
                // Text before any heading reads as the gist.
                if page.sections.isEmpty {
                    if case .paragraph(let text) = item { page.lead.append(text) } else {
                        page.sections.append(Section(id: 0, lines: [item]))
                    }
                } else {
                    page.sections[page.sections.count - 1].lines.append(item)
                }
            }
        }
        return page
    }

    var body: some View {
        let page = page
        VStack(alignment: .leading, spacing: 22) {
            if let title = page.title {
                Text(inline(title, last: page.lead.isEmpty && page.sections.isEmpty))
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            if !page.lead.isEmpty {
                Text(inline(page.lead.joined(separator: " "), last: page.sections.isEmpty))
                    .font(.system(size: 20))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ink)
            }
            ForEach(page.sections) { section in
                sectionView(section, isLast: section.id == page.sections.count - 1)
                    .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .identity))
            }
        }
        .animation(.easeOut(duration: 0.35), value: page.sections.count)
        .tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The icon leads the heading on its line; everything sits on one left edge.
    private func sectionView(_ section: Section, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading = section.heading, !heading.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image("phosphor/topic-\(section.topic ?? Self.topic(for: heading))")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(Theme.ink)
                    Text(inline(heading, last: isLast && section.lines.isEmpty))
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            ForEach(Array(section.lines.enumerated()), id: \.offset) { index, line in
                let last = isLast && index == section.lines.count - 1
                switch line {
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("·").foregroundStyle(Theme.faintInk)
                        Text(inline(text, last: last))
                    }
                case .paragraph(let text):
                    Text(inline(text, last: last))
                }
            }
            .font(.body)
            .lineSpacing(3)
            .foregroundStyle(Theme.secondaryInk)
        }
    }

    /// When the model didn't tag a section, a fitting icon from words in its heading.
    private static func topic(for heading: String) -> String {
        let words = heading.lowercased()
        let hints: [(String, [String])] = [
            ("money", ["cost", "price", "pay", "budget", "cheap", "fee", "money", "cijen"]),
            ("time", ["when", "time", "hour", "how long", "schedule", "vrijeme"]),
            ("date", ["date", "year", "history", "season", "day"]),
            ("place", ["where", "location", "area", "district", "town", "city", "visit", "gdje"]),
            ("privacy", ["privacy", "security", "safe", "protect"]),
            ("speed", ["speed", "fast", "performance", "quick"]),
            ("warning", ["risk", "warning", "missing", "caution", "limit", "downside", "con"]),
            ("people", ["who", "people", "team", "family", "kids", "community"]),
            ("food", ["food", "eat", "drink", "restaurant", "coffee", "hrana"]),
            ("travel", ["travel", "getting", "transport", "trip", "flight"]),
            ("compare", ["compare", "vs", "versus", "alternative", "option"]),
            ("star", ["best", "top", "highlight", "recommend"]),
            ("trend", ["trend", "growth", "market", "future"]),
            ("learn", ["learn", "background", "about", "what is", "overview"]),
            ("tools", ["how to", "setup", "use", "feature", "tool"]),
            ("news", ["news", "latest", "update", "announce"]),
        ]
        for (topic, keys) in hints where keys.contains(where: words.contains) { return topic }
        return "idea"
    }

    /// Inline emphasis and links; the last piece of text carries the caret while streaming.
    private func inline(_ text: String, last: Bool) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Bold terms read in full ink, ahead of the softer body.
        for run in result.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            result[run.range].foregroundColor = Theme.ink
        }
        if last && isStreaming {
            var caret = AttributedString(" ▍")
            caret.foregroundColor = Theme.accent
            result += caret
        }
        return result
    }

    /// "[privacy] Privacy first" → ("privacy", "Privacy first"). Unknown tags
    /// are dropped, and so is any emoji a model adds anyway.
    private static func splitTopic(_ raw: String) -> (String?, String) {
        var heading = Substring(raw)
        var topic: String?
        if heading.hasPrefix("["), let close = heading.firstIndex(of: "]") {
            let tag = heading[heading.index(after: heading.startIndex)..<close].lowercased()
            topic = AnswerTopic.all.contains(tag) ? tag : nil
            heading = heading[heading.index(after: close)...]
        }
        if topic == nil, AnswerTopic.all.contains(heading.trimmingCharacters(in: .whitespaces).lowercased()) {
            return (heading.trimmingCharacters(in: .whitespaces).lowercased(), "")
        }
        let text = String(heading).unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000) }
        return (topic, String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespaces))
    }
}

/// A status line with a soft light passing over it while work is going on.
struct StatusLine: View {
    let text: String
    var font: Font = .body

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Theme.faintInk)
            .overlay {
                // The same words in full ink, revealed by a moving band. Drawn
                // as an overlay, so the plain line shows even if this never runs.
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Text(text)
                        .font(font)
                        .foregroundStyle(Theme.ink)
                        .mask {
                            GeometryReader { proxy in
                                LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: proxy.size.width * 0.5)
                                    .offset(x: (phase * 1.5 - 0.5) * proxy.size.width)
                            }
                        }
                }
                .accessibilityHidden(true)
            }
    }
}
