import SwiftUI

/// Lays out the Markdown the AI features write as a small page: a title, the
/// gist set large ("> " line), the key points ("> - ") and the picks to choose
/// from ("=> name | figure | who it suits"), then sections whose topic icon
/// leads the heading. A long answer opens with a row of its sections to jump
/// to. While text is still arriving, an orange caret follows the last word,
/// and each new section settles in.
struct MarkdownText: View {
    let markdown: String
    var isStreaming = false
    /// The pages "[[2]]" marks point at, in order; without them the marks are dropped.
    var sources: [URL] = []
    /// Opens a source page from its mark.
    var openSource: ((URL) -> Void)? = nil
    /// Scrolls the page to a section, by the id each section gets from `anchor`.
    var jump: ((String) -> Void)? = nil
    /// Makes section ids unique on a page holding more than one answer.
    var anchor = "answer"

    private struct Section: Identifiable {
        let id: Int
        var topic: String?
        var heading: String?
        var lines: [Line] = []
    }

    private enum Line {
        case bullet(String), paragraph(String)
    }

    private struct Pick: Identifiable {
        let id: Int
        var name: String
        var figure: String
        var suits: String
    }

    private struct Page {
        var title: String?
        var lead: [String] = []
        var keyPoints: [String] = []
        var picks: [Pick] = []
        var sections: [Section] = []
    }

    private var page: Page {
        var page = Page()
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A heading still being written ("#", "##"): wait for its words.
            if line.allSatisfy({ $0 == "#" }) || line == ">" || line == "=>" || line == "> -" { continue }
            if line.hasPrefix("## ") {
                let (topic, heading) = Self.splitTopic(String(line.dropFirst(3)))
                page.sections.append(Section(id: page.sections.count, topic: topic, heading: heading))
            } else if line.hasPrefix("# ") {
                page.title = String(line.dropFirst(2))
            } else if line.hasPrefix("=> ") {
                let parts = line.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
                guard let name = parts.first, !name.isEmpty else { continue }
                page.picks.append(Pick(id: page.picks.count, name: name,
                                       figure: parts.count > 1 ? parts[1] : "", suits: parts.count > 2 ? parts[2] : ""))
            } else if line.hasPrefix("> - ") || line.hasPrefix(">- ") {
                page.keyPoints.append(String(line.drop { $0 != "-" }.dropFirst()).trimmingCharacters(in: .whitespaces))
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
        // Whichever block is written last carries the caret.
        let afterLead = !page.keyPoints.isEmpty || !page.picks.isEmpty || !page.sections.isEmpty
        VStack(alignment: .leading, spacing: 28) {
            if let title = page.title {
                Text(inline(title, last: page.lead.isEmpty && !afterLead))
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            if !page.lead.isEmpty || !page.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    if !page.lead.isEmpty {
                        Text(inline(page.lead.joined(separator: " "), last: !afterLead))
                            .font(.system(size: 20))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.ink)
                    }
                    let points = Self.newPoints(page.keyPoints, after: page.lead.joined(separator: " "))
                    if !points.isEmpty { keyPoints(points, lastIsLive: page.picks.isEmpty && page.sections.isEmpty) }
                }
            }
            if !page.picks.isEmpty { picks(page.picks) }
            if page.sections.count >= 4, !isStreaming, jump != nil { sectionChips(page.sections) }
            ForEach(page.sections) { section in
                sectionView(section, isLast: section.id == page.sections.count - 1)
                    .id("\(anchor)-section-\(section.id)")
                    .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .identity))
            }
        }
        .animation(.easeOut(duration: 0.35), value: page.sections.count)
        .animation(.easeOut(duration: 0.3), value: page.picks.count)
        .textSelection(.enabled)
        .tint(Theme.accent)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "roko-source", let number = Int(url.host() ?? ""), sources.indices.contains(number - 1) else {
                return .systemAction
            }
            openSource?(sources[number - 1])
            return .handled
        })
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Blocks

    /// Key points that say something the gist doesn't: a small model often
    /// repeats the gist as its first point, nearly word for word.
    private static func newPoints(_ points: [String], after gist: String) -> [String] {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let said = words(gist)
        return points.filter { point in
            let own = words(point)
            return own.isEmpty || Double(own.intersection(said).count) / Double(own.count) < 0.75
        }
    }

    /// The three things most worth knowing, in full ink under the gist.
    private func keyPoints(_ points: [String], lastIsLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image("phosphor/topic-check")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundStyle(Theme.secondaryInk)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    Text(inline(point, last: lastIsLive && index == points.count - 1))
                        .font(.system(size: 17))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    /// What to choose, best first: each option's name and who it suits, its
    /// price or deciding number on the right, so the verdict is read before
    /// the details that back it.
    private func picks(_ picks: [Pick]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(picks) { pick in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pick.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if !pick.suits.isEmpty {
                            Text(pick.suits)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    Spacer(minLength: 8)
                    // Only a real figure: a model sometimes writes "no price given".
                    if pick.figure.contains(where: \.isNumber) {
                        Text(pick.figure)
                            .font(.system(size: 16, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130, alignment: .trailing)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                if pick.id < picks.count - 1 {
                    // Rows parted by the panel itself showing through, not a rule.
                    Theme.canvas.frame(height: 2)
                }
            }
        }
        .background(Theme.raised.opacity(0.7), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.edge))
        .textSelection(.disabled)
    }

    /// The sections of a long answer, to jump to.
    private func sectionChips(_ sections: [Section]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(sections.filter { !($0.heading ?? "").isEmpty }) { section in
                    Button {
                        jump?("\(anchor)-section-\(section.id)")
                    } label: {
                        Text(section.heading ?? "")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Theme.raised, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityHint("Goes to this part of the answer")
                }
            }
        }
        .scrollIndicators(.hidden)
        // Out to the screen's edges, the first one still on the text's edge.
        .contentMargins(.horizontal, 22, for: .scrollContent)
        .padding(.horizontal, -22)
        .transition(.opacity)
    }

    /// The icon, when one fits, leads the heading on its line.
    private func sectionView(_ section: Section, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heading = section.heading, !heading.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    if let topic = section.topic ?? Self.topic(for: heading) {
                        Image("phosphor/topic-\(topic)")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(Theme.ink)
                    }
                    Text(inline(heading, last: isLast && section.lines.isEmpty))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { index, line in
                    let last = isLast && index == section.lines.count - 1
                    switch line {
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·").foregroundStyle(Theme.faintInk)
                            Text(inline(text, last: last))
                        }
                    case .paragraph(let text):
                        Text(inline(text, last: last))
                    }
                }
            }
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(Theme.bodyInk)
        }
    }

    /// When the model didn't tag a section, an icon from a word in its heading,
    /// as a whole word ("con" isn't "counter"); none when nothing fits.
    private static func topic(for heading: String) -> String? {
        let words = Set(heading.lowercased().split { !$0.isLetter }.map(String.init))
        let hints: [(String, [String])] = [
            ("weather", ["weather", "climate", "temperature", "rain", "snow", "sunshine"]),
            ("money", ["cost", "costs", "price", "prices", "pay", "budget", "cheap", "cheaper", "fee", "fees", "money", "spend", "value"]),
            ("time", ["when", "time", "hours", "long", "schedule"]),
            ("date", ["date", "year", "history", "season"]),
            ("place", ["where", "location", "area", "district", "town", "city"]),
            ("privacy", ["privacy", "security", "safe", "safety"]),
            ("warning", ["risk", "risks", "warning", "caution", "limits", "downsides", "drawbacks", "cons", "caveat"]),
            ("people", ["who", "people", "team", "family", "kids"]),
            ("food", ["food", "eat", "drink", "restaurant", "restaurants", "coffee", "dish", "menu", "cuisine"]),
            ("travel", ["travel", "transport", "trip", "flight", "flights"]),
            ("compare", ["compare", "vs", "versus", "alternative", "alternatives", "options"]),
            ("star", ["best", "top", "pick", "picks", "recommended"]),
            ("news", ["news", "latest", "update", "announced"]),
        ]
        for (topic, keys) in hints where keys.contains(where: words.contains) { return topic }
        return nil
    }

    // MARK: Inline

    /// Inline emphasis, links and source marks; numbers and prices in full
    /// ink, so they can be found at a glance. The last piece of text carries
    /// the caret while streaming.
    private func inline(_ text: String, last: Bool) -> AttributedString {
        var text = text
        if last && isStreaming {
            // A bold term still arriving: closed for now, so it reads bold as it
            // grows instead of showing its asterisks until the closing pair comes.
            if text.hasSuffix("*") && !text.hasSuffix("**") { text.removeLast() }
            if text.components(separatedBy: "**").count % 2 == 0 {
                if text.hasSuffix("**") {
                    text.removeLast(2)
                } else {
                    // Before any trailing space: "**Bolt or **" wouldn't read as bold.
                    let trailing = text.reversed().prefix(while: \.isWhitespace).count
                    text.insert(contentsOf: "**", at: text.index(text.endIndex, offsetBy: -trailing))
                }
            }
            // A mark still arriving ("[[2"): left out until it's whole.
            if let open = text.range(of: "[[", options: .backwards), !text[open.upperBound...].contains("]]") {
                text.removeSubrange(open.lowerBound...)
            }
        }
        text = sourceMarks(in: text)
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Bold terms read in full ink, ahead of the softer body.
        for run in result.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            result[run.range].foregroundColor = Theme.ink
        }
        // Prices, percentages and measures: in full ink, where the eye looks for them.
        let plain = String(result.characters)
        for match in plain.matches(of: Self.figure) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            if result[lower..<upper].runs.contains(where: { $0.link != nil }) { continue }
            result[lower..<upper].foregroundColor = Theme.ink
        }
        // Source marks: small and raised, after the words they back.
        for run in result.runs where run.link?.scheme == "roko-source" {
            result[run.range].font = .system(size: 11, weight: .semibold)
            result[run.range].baselineOffset = 6
        }
        if last && isStreaming {
            var caret = AttributedString(" ▍")
            caret.foregroundColor = Theme.accent
            result += caret
        }
        return result
    }

    /// "[[2,5]]" as tappable numbers for the source cards, or nothing when
    /// there are no sources to open.
    private func sourceMarks(in text: String) -> String {
        guard text.contains("[[") else { return text }
        return text.replacing(Self.mark) { match in
            guard openSource != nil, !sources.isEmpty else { return "" }
            let numbers = match.output.1.split(separator: ",").compactMap { Int($0) }.filter { sources.indices.contains($0 - 1) }
            return numbers.map { "\u{2009}[\($0)](roko-source://\($0))" }.joined()
        }
    }

    nonisolated(unsafe) private static let mark = /\[\[([\d,]+)\]\]/
    /// A price, percentage or measure: "$499", "€1,299", "45%", "30 hours", "1.1 L".
    nonisolated(unsafe) private static let figure =
        /(?:[$€£¥]\s?\d[\d,.]*(?:\s?(?:k|m|bn|million|billion))?|\d[\d,.]*\s?(?:%|€|\$|USD|EUR|GBP|kn|kg|g|km|m|mph|km\/h|hours?|hrs?|minutes?|min|days?|years?|GB|TB|MB|mAh|W|Hz|L|ml|°C|°F|inches|in|cm|mm|bar))(?![\w])/

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
