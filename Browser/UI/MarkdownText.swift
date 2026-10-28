import SwiftUI

/// What a summary or an answer is about, which decides its shape and its one
/// quiet colour: a recipe gets its ingredients to tick and its steps, a how-to
/// its steps, a comparison its trade-offs side by side.
nonisolated enum PageKind: String, CaseIterable, Sendable {
    case recipe, howto, compare, article, general

    static let names = allCases.map(\.rawValue)

    /// A low-saturation tint, never the accent: for the big numbers, the step
    /// numbers, the section bands and the reading line.
    @MainActor var tint: Color {
        switch self {
        case .recipe: Color(light: 0x9A5B22, dark: 0xE8B98A)   // apricot
        case .howto: Color(light: 0x4C6B45, dark: 0xA9C7A1)    // sage
        case .compare: Color(light: 0x2F6662, dark: 0x95C4C0)  // sea glass
        case .article: Color(light: 0x6A5F52, dark: 0xCFC6B8)  // stone
        case .general: Theme.ink
        }
    }

    /// The page's kind, from its "@ kind" line.
    @MainActor static func of(_ markdown: String) -> PageKind {
        MarkdownText(markdown: markdown).kind
    }
}

/// Lays out the Markdown the AI features write as a small page, its shape
/// taken from what's in it:
///
///     @ recipe                       what kind of page, for its colour
///     # Title
///     %% 25 min | total              big numbers, up to three
///     > The gist                     set large
///     > - A key point                three things worth knowing
///     => Name | $299 | who it suits  the options to choose, best first
///     ## [topic] Heading             a section, its icon when one fits
///     - **Term:** detail             a bullet
///     [] Spaghetti | 200 g           a thing to have, ticked off by a tap
///     1. Boil the pasta              a step, marked done by a tap
///     <> | Roomba | Dreame           a side-by-side: the header row,
///     <> Carpet hair | 98% | 91%     then a row per point
///     @@ Jan Grue | author | point   who says what
///     !! Lose your key and ...       the one thing to watch out for
///
/// While text is still arriving, an orange caret follows the last word, and
/// each new block settles in.
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

    /// Things ticked and steps done, by their text: for this page while it's open.
    @State private var done: Set<String> = []

    private struct Section: Identifiable {
        let id: Int
        var topic: String?
        var heading: String?
        var lines: [Line] = []
    }

    private enum Line {
        case bullet(String), paragraph(String)
        case check(item: String, amount: String)
        case step(Int, String)
        case versus(label: String, a: String, b: String)
        case person(name: String, role: String, point: String)
        case warning(String)

        /// Lines drawn together as one block (a checklist, a table) share a group.
        var group: Int {
            switch self {
            case .bullet, .paragraph: 0
            case .check: 1
            case .step: 2
            case .versus: 3
            case .person: 4
            case .warning: 5
            }
        }
    }

    private struct Pick: Identifiable {
        let id: Int
        var name: String
        var figure: String
        var suits: String
    }

    private struct Stat: Identifiable {
        let id: Int
        var value: String
        var label: String
    }

    private struct Page {
        var kind = PageKind.general
        var title: String?
        var stats: [Stat] = []
        var lead: [String] = []
        var keyPoints: [String] = []
        var picks: [Pick] = []
        var sections: [Section] = []
    }

    // MARK: Reading the Markdown

    /// What kind of page this is, said or guessed: for its colour.
    var kind: PageKind { page.kind }

    private var page: Page {
        var page = Page()
        func add(_ item: Line) {
            if page.sections.isEmpty { page.sections.append(Section(id: 0)) }
            page.sections[page.sections.count - 1].lines.append(item)
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // The page's kind run into the next line ("@ howto > Squeaky
            // doors...", or "> howto Squeaky..."): taken off, the rest read on.
            if let match = line.firstMatch(of: Self.kindPrefix), let kind = PageKind(rawValue: match.output.2.lowercased()),
               !match.output.3.isEmpty {
                page.kind = kind
                line = String(match.output.1 ?? "") + match.output.3
            }
            // The page's kind on a line of its own, without its "@".
            let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: ">@ ")).lowercased()
            if let kind = PageKind(rawValue: bare), bare.count == line.count || line.count - bare.count <= 3 {
                page.kind = kind
                continue
            }
            // A line still being written ("#", "=>"): wait for its words.
            if ["#", "##", ">", "=>", "> -", "%%", "[]", "<>", "@@", "!!", "@"].contains(line) { continue }
            if line.hasPrefix("@"), !line.hasPrefix("@@"), line.count < 14 {
                page.kind = PageKind(rawValue: line.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()) ?? .general
            } else if line.hasPrefix("## ") {
                let (topic, heading) = Self.splitTopic(String(line.dropFirst(3)))
                page.sections.append(Section(id: page.sections.count, topic: topic, heading: heading))
            } else if line.hasPrefix("# ") {
                page.title = String(line.dropFirst(2))
            } else if line.hasPrefix("%% ") {
                let parts = Self.fields(line.dropFirst(3))
                if let value = parts.first, !value.isEmpty, !Self.isDate(value), page.stats.count < 3 {
                    page.stats.append(Self.stat(id: page.stats.count, value: value, label: parts.count > 1 ? parts[1] : ""))
                }
            } else if line.hasPrefix("=> ") {
                let parts = Self.fields(line.dropFirst(3))
                guard let name = parts.first, !name.isEmpty else { continue }
                page.picks.append(Pick(id: page.picks.count, name: name,
                                       figure: parts.count > 1 ? parts[1] : "", suits: parts.count > 2 ? parts[2] : ""))
            } else if line.hasPrefix("> - ") || line.hasPrefix(">- ") {
                page.keyPoints.append(String(line.drop { $0 != "-" }.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(">") {
                page.lead.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("[] ") || line.hasPrefix("[ ] ") {
                let parts = Self.fields(line.drop { $0 != "]" }.dropFirst())
                if var item = parts.first, !item.isEmpty {
                    let amount = parts.count > 1 ? parts[1] : ""
                    // "350g spaghetti | 350g": the amount once, on the right.
                    if let first = amount.split(separator: " ").first, item.hasPrefix(first + " ") {
                        item = String(item.dropFirst(first.count + 1))
                        item = item.prefix(1).uppercased() + item.dropFirst()
                    }
                    add(.check(item: item.prefix(1).uppercased() + item.dropFirst(), amount: amount))
                }
            } else if let match = line.wholeMatch(of: /(\d{1,2})[.)]\s+(.+)/) {
                add(.step(Int(match.output.1) ?? 1, String(match.output.2)))
            } else if line.hasPrefix("<> ") {
                let parts = Self.fields(line.dropFirst(2))
                if parts.count >= 3 { add(.versus(label: parts[0], a: parts[1], b: parts[2])) }
            } else if line.hasPrefix("@@ ") {
                let parts = Self.fields(line.dropFirst(3))
                if let name = parts.first, !name.isEmpty {
                    add(.person(name: name, role: parts.count > 1 ? parts[1] : "", point: parts.count > 2 ? parts[2] : ""))
                }
            } else if line.hasPrefix("!! ") {
                add(.warning(String(line.dropFirst(3))))
            } else {
                let item: Line = line.hasPrefix("- ") || line.hasPrefix("* ")
                    ? .bullet(String(line.dropFirst(2))) : .paragraph(line)
                // Text before any heading reads as the gist.
                if page.sections.isEmpty, case .paragraph(let text) = item {
                    page.lead.append(text)
                } else {
                    add(item)
                }
            }
        }
        if page.kind == .general { page.kind = Self.kind(guessedFrom: page) }
        // News and essays lead with their gist: a big number over them was
        // always one the model reached for, never one the reader came for.
        if page.kind == .article { page.stats = [] }
        // Nor an ingredient's amount: "350g pasta" or "3 eggs" up top only
        // repeats a line of the list below, and pushes the time out of view.
        let items = page.sections.flatMap(\.lines).compactMap { line -> (name: String, amount: String)? in
            if case .check(let item, let amount) = line { (item.lowercased(), amount.lowercased()) } else { nil }
        }
        page.stats.removeAll { stat in
            let label = stat.label.lowercased().trimmingCharacters(in: .whitespaces)
            let value = stat.value.lowercased().replacingOccurrences(of: " ", with: "")
            return items.contains { item in
                !label.isEmpty && (item.name.contains(label) || label.contains(item.name))
                    || !item.amount.isEmpty && item.amount.replacingOccurrences(of: " ", with: "") == value
            }
        }
        return page
    }

    /// When the model didn't say what the page is, what its blocks say:
    /// things to have and steps make a recipe (with amounts) or a how-to,
    /// options to choose or two side by side a comparison, people an article.
    private static func kind(guessedFrom page: Page) -> PageKind {
        let lines = page.sections.flatMap(\.lines)
        let checks = lines.compactMap { line -> String? in if case .check(_, let amount) = line { amount } else { nil } }
        let hasSteps = lines.contains { if case .step = $0 { true } else { false } }
        if !checks.isEmpty && hasSteps {
            let measured = checks.filter { $0.contains(where: \.isNumber) }.count
            return measured * 2 >= checks.count && page.sections.contains { $0.topic == "food" } ? .recipe : .howto
        }
        if hasSteps { return .howto }
        if !page.picks.isEmpty || lines.contains(where: { if case .versus = $0 { true } else { false } }) { return .compare }
        if lines.contains(where: { if case .person = $0 { true } else { false } }) { return .article }
        return .general
    }

    /// A year or a date isn't a number anyone came for, however the model
    /// felt about it: "2028" over a story about the Olympics set nothing up.
    private static func isDate(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces)
        return value.wholeMatch(of: /(1[5-9]|20)\d{2}\.?/) != nil
            // "12. 3." or "12. 3. 2025." (but not 4.2), or "3/14/2025".
            || value.wholeMatch(of: /\d{1,2}\.\s?\d{1,2}\.(\s?\d{4}\.?)?/) != nil
            || value.wholeMatch(of: /\d{1,2}\/\d{1,2}\/\d{2,4}/) != nil
    }

    /// A big number kept short: "4 servings" over "servings" is "4", and
    /// "30 minutes" is "30 min".
    private static func stat(id: Int, value: String, label: String) -> Stat {
        var value = value
        let words = value.split(separator: " ")
        if words.count > 1, let last = words.last, label.lowercased().contains(last.lowercased()) {
            value = words.dropLast().joined(separator: " ")
        }
        for (long, short) in [("minutes", "min"), ("minute", "min"), ("hours", "h"), ("hour", "h"), ("seconds", "s")] {
            value = value.replacingOccurrences(of: " \(long)", with: " \(short)")
        }
        return Stat(id: id, value: value, label: label)
    }

    /// A row's " | " parts, without bold marks or source marks: an amount or
    /// a price has no room for a "[[1]]".
    private static func fields(_ text: Substring) -> [String] {
        text.replacing(Self.mark, with: "")
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
    }

    // MARK: Layout

    var body: some View {
        let page = page
        let tint = page.kind.tint
        // Whichever block is written last carries the caret.
        let afterLead = !page.keyPoints.isEmpty || !page.picks.isEmpty || !page.sections.isEmpty
        VStack(alignment: .leading, spacing: 30) {
            if page.title != nil || !page.stats.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    if let title = page.title {
                        Text(inline(title, last: page.lead.isEmpty && !afterLead && page.stats.isEmpty))
                            .font(.system(.title2, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    if !page.stats.isEmpty { stats(page.stats, tint: tint) }
                }
            }
            if !page.lead.isEmpty || !page.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    if !page.lead.isEmpty {
                        Text(inline(page.lead.joined(separator: " "), last: !afterLead))
                            .font(.system(size: 20))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                    let points = Self.newPoints(page.keyPoints, after: page.lead.joined(separator: " "))
                    if !points.isEmpty {
                        keyPoints(points, tint: tint, lastIsLive: page.picks.isEmpty && page.sections.isEmpty)
                    }
                }
            }
            if !page.picks.isEmpty { picks(page.picks, tint: tint) }
            let headed = page.sections.filter { !($0.heading ?? "").isEmpty }
            if headed.count >= 4, !isStreaming, jump != nil { sectionChips(headed) }
            ForEach(page.sections) { section in
                sectionView(section, isLast: section.id == page.sections.count - 1, tint: tint,
                            banded: page.kind != .general && section.id % 2 == 1)
                    .id("\(anchor)-section-\(section.id)")
                    .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .identity))
            }
        }
        .animation(.smooth(duration: 0.45), value: page.sections.count)
        .animation(.smooth(duration: 0.4), value: page.picks.count)
        .animation(.smooth(duration: 0.4), value: page.stats.count)
        .animation(.snappy(duration: 0.3), value: done)
        .sensoryFeedback(.selection, trigger: done)
        // Links and source marks in the page's colour, or quiet grey on an untyped page.
        .tint(page.kind == .general ? Theme.secondaryInk : tint)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "roko-source", let number = Int(url.host() ?? ""), sources.indices.contains(number - 1) else {
                return .systemAction
            }
            openSource?(sources[number - 1])
            return .handled
        })
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Opening blocks

    /// The numbers that matter most, large, in the page's colour: "25 min",
    /// "2", "Easy". Each grows into place as it's written.
    private func stats(_ stats: [Stat], tint: Color) -> some View {
        // Equal columns across the text's width, whatever each number's length.
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value)
                        .font(.system(size: stats.count == 1 ? 40 : 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !stat.label.isEmpty {
                        Text(stat.label)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: stats.count == 1 ? nil : .infinity, alignment: .leading)
                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
    }

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
    private func keyPoints(_ points: [String], tint: Color, lastIsLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image("phosphor/topic-check")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(tint.opacity(0.85))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    Text(inline(point, last: lastIsLive && index == points.count - 1))
                        .font(.system(size: 17))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// What to choose, best first: each option's name and who it suits on the
    /// left, its price on the right. The first is the verdict, so its name
    /// takes the page's colour.
    private func picks(_ picks: [Pick], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(picks) { pick in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pick.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(pick.id == 0 ? tint : Theme.ink)
                        if !pick.suits.isEmpty {
                            Text(pick.suits)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    // The words take all the room the price doesn't need.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Only a real figure: a model sometimes writes "no price given".
                    if pick.figure.contains(where: \.isNumber) {
                        Text(pick.figure)
                            .font(.system(size: 17, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: pick.figure.count <= 12, vertical: false)
                            .frame(maxWidth: pick.figure.count <= 12 ? nil : 120, alignment: .trailing)
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .transition(.offset(y: 10).combined(with: .opacity))
            }
        }
        .background(Theme.raised.opacity(0.75), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.edge))
    }

    /// The sections of a long answer, to jump to.
    private func sectionChips(_ sections: [Section]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    Button {
                        jump?("\(anchor)-section-\(section.id)")
                    } label: {
                        // Quieter than the text around them: a way in, not a headline.
                        Text(section.heading ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Theme.raised.opacity(0.6), in: .capsule)
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

    // MARK: Sections

    /// A heading (its icon leading it when one fits) over its blocks. Every
    /// other section of a typed page sits on a faint band of the page's
    /// colour, so the page reads as blocks rather than one long column.
    private func sectionView(_ section: Section, isLast: Bool, tint: Color, banded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let heading = section.heading, !heading.isEmpty {
                // No icon over steps or a checklist: their own circles are
                // the marks, and a second one above them competes.
                let marked = section.lines.contains { $0.group == 1 || $0.group == 2 }
                HStack(alignment: .center, spacing: 10) {
                    if !marked, let topic = section.topic ?? Self.topic(for: heading) {
                        Image("phosphor/topic-\(topic)")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(tint)
                    }
                    Text(inline(heading, last: isLast && section.lines.isEmpty))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            let runs = Self.runs(section.lines)
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                block(run, live: isLast && index == runs.count - 1, tint: tint)
            }
        }
        // A band is exactly as wide as every other box on the page, so all
        // their edges line up down the screen.
        .padding(.vertical, banded ? 18 : 0)
        .padding(.horizontal, banded ? 16 : 0)
        .background {
            if banded {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tint.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.08)))
            }
        }
        .environment(\.inBand, banded)
    }

    /// Lines in runs of the same kind, so a checklist or a table is one block.
    private static func runs(_ lines: [Line]) -> [[Line]] {
        var runs: [[Line]] = []
        for line in lines {
            if let last = runs.last?.last, last.group == line.group, line.group != 5 {
                runs[runs.count - 1].append(line)
            } else {
                runs.append([line])
            }
        }
        return runs
    }

    @ViewBuilder
    private func block(_ run: [Line], live: Bool, tint: Color) -> some View {
        switch run.first {
        case .check: checklist(run, tint: tint)
        case .step: steps(run, live: live, tint: tint)
        case .versus: versus(run, tint: tint)
        case .person: people(run, live: live)
        case .warning(let text): warning(text, live: live)
        default: prose(run, live: live)
        }
    }

    private func prose(_ run: [Line], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(run.enumerated()), id: \.offset) { index, line in
                let last = live && index == run.count - 1
                switch line {
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("·").foregroundStyle(Theme.faintInk)
                        Text(inline(text, last: last)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .paragraph(let text):
                    Text(inline(text, last: last))
                default:
                    EmptyView()
                }
            }
        }
        .font(.body)
        .lineSpacing(4)
        .foregroundStyle(Theme.bodyInk)
        .textSelection(.enabled)
    }

    /// Things to have, ticked off with a tap; the amount on the right.
    private func checklist(_ run: [Line], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(run.enumerated()), id: \.offset) { _, line in
                if case .check(let item, let amount) = line {
                    let key = "check:" + item
                    let ticked = done.contains(key)
                    Button {
                        if ticked { done.remove(key) } else { done.insert(key) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            ZStack {
                                Circle().strokeBorder(ticked ? tint : Theme.faintInk, lineWidth: 1.6)
                                if ticked {
                                    Circle().fill(tint)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Theme.canvas)
                                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                                }
                            }
                            .frame(width: 22, height: 22)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                            // A note ("sized to your tire") reads under the item, on
                            // its edge; only a short amount ("100g") sits on the right.
                            let isNote = Self.isNote(amount)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item)
                                    .font(.body)
                                    .foregroundStyle(ticked ? Theme.secondaryInk : Theme.ink)
                                    .strikethrough(ticked, color: Theme.secondaryInk)
                                if isNote {
                                    Text(amount)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if !amount.isEmpty, !isNote {
                                Text(amount)
                                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                                    .foregroundStyle(ticked ? Theme.secondaryInk : Theme.ink)
                            }
                        }
                        .padding(.vertical, 10)
                        .modifier(BandInset(amount: 16))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(ticked ? .isSelected : [])
                }
            }
        }
        .modifier(Panel(padding: 4))
    }

    /// Words rather than an amount: more than two words, or no digit in a
    /// phrase longer than "a pinch".
    private static func isNote(_ amount: String) -> Bool {
        let words = amount.split(separator: " ").count
        return words > 2 || (!amount.contains(where: \.isNumber) && amount.count > 8)
    }

    /// Steps in order: tap a number to mark it done. The first one not done is
    /// lit in the page's colour, the done ones step back.
    private func steps(_ run: [Line], live: Bool, tint: Color) -> some View {
        let keys = run.compactMap { line -> String? in if case .step(_, let text) = line { "step:" + text } else { nil } }
        let current = keys.first { !done.contains($0) }
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(run.enumerated()), id: \.offset) { index, line in
                if case .step(let number, let text) = line {
                    let key = "step:" + text
                    let finished = done.contains(key)
                    let isCurrent = key == current
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Button {
                            if finished { done.remove(key) } else { done.insert(key) }
                        } label: {
                            ZStack {
                                Circle().fill(isCurrent ? tint : tint.opacity(0.14))
                                if finished {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(tint)
                                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                                } else {
                                    Text("\(number)")
                                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(isCurrent ? Theme.canvas : tint)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .contentShape(.rect.inset(by: -8))
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        .accessibilityLabel(finished ? "Step \(number), done" : "Mark step \(number) done")
                        Text(inline(text, last: live && index == run.count - 1))
                            .font(.system(size: 17))
                            .lineSpacing(4)
                            .foregroundStyle(finished ? Theme.secondaryInk : isCurrent ? Theme.ink : Theme.bodyInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .opacity(finished ? 0.6 : 1)
                }
            }
        }
    }

    /// Two options side by side, a row per point; the header names them.
    private func versus(_ run: [Line], tint: Color) -> some View {
        let rows = run.compactMap { line -> (String, String, String)? in
            if case .versus(let label, let a, let b) = line { (label, a, b) } else { nil }
        }
        let header = rows.first { $0.0.isEmpty }
        let points = rows.filter { !$0.0.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            if let header {
                row("", header.1, header.2, isHeader: true, tint: tint)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, item in
                row(item.0, item.1, item.2, isHeader: false, tint: tint)
            }
        }
        .modifier(Panel(padding: 6))
        .textSelection(.enabled)
    }

    /// Three columns on one grid: the point, then each option's value, every
    /// cell on its column's left edge so wrapped words stay lined up.
    private func row(_ label: String, _ a: String, _ b: String, isHeader: Bool, tint: Color) -> some View {
        HStack(alignment: isHeader ? .bottom : .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(a)
                .frame(width: 104, alignment: .leading)
            Text(b)
                .frame(width: 104, alignment: .leading)
        }
        .font(.system(size: isHeader ? 13 : 16, weight: isHeader ? .semibold : .medium).monospacedDigit())
        .foregroundStyle(isHeader ? tint : Theme.ink)
        .multilineTextAlignment(.leading)
        .lineLimit(3)
        .padding(.vertical, isHeader ? 8 : 9)
        .modifier(BandInset(amount: 16))
    }

    /// Who says what: the name and role, then their point.
    private func people(_ run: [Line], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(run.enumerated()), id: \.offset) { index, line in
                if case .person(let name, let role, let point) = line {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                            if !role.isEmpty {
                                Text(role).font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        if !point.isEmpty {
                            Text(inline(point, last: live && index == run.count - 1))
                                .font(.body)
                                .lineSpacing(4)
                                .foregroundStyle(Theme.bodyInk)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// The one thing to watch out for, on a warm tint whatever the page.
    private func warning(_ text: String, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image("phosphor/topic-warning")
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(inline(text, last: live))
                .font(.body)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Self.warningInk)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Self.warningFill, in: .rect(cornerRadius: 16, style: .continuous))
        .textSelection(.enabled)
    }

    private static let warningFill = Color(light: 0xF4E6D3, dark: 0x2B2219)
    private static let warningInk = Color(light: 0x6B4515, dark: 0xE6CDAA)

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
            ("food", ["food", "eat", "drink", "restaurant", "restaurants", "coffee", "dish", "menu", "cuisine", "ingredients"]),
            ("travel", ["travel", "transport", "trip", "flight", "flights"]),
            ("compare", ["compare", "vs", "versus", "alternative", "alternatives", "options", "trade"]),
            ("star", ["best", "top", "pick", "picks", "recommended"]),
            ("check", ["steps", "method", "instructions"]),
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
        var text = Self.withoutEchoes(text)
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
        // In the page's own colour (orange clashed with a sage or sea-glass
        // band); on an untyped page, quiet grey, with the orange kept for the caret.
        let markColor = kind == .general ? Theme.secondaryInk : kind.tint
        for run in result.runs where run.link?.scheme == "roko-source" {
            result[run.range].font = .system(size: 11, weight: .semibold)
            result[run.range].baselineOffset = 6
            result[run.range].foregroundColor = markColor
        }
        if last && isStreaming {
            var caret = AttributedString(" ▍")
            caret.foregroundColor = Theme.accent
            result += caret
        }
        return result
    }

    /// A sentence that only says the one before it again ("Rinse, then boil
    /// a kettle of water. Pour away, rinse, then boil and discard a kettle of
    /// water."), dropped; its source mark goes to the one kept.
    private static func withoutEchoes(_ text: String) -> String {
        // Sentences end at ". " (after any source mark) before a capital or a digit.
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard character == " ", index + 1 < characters.count,
                  let next = characters[index + 1].unicodeScalars.first,
                  CharacterSet.uppercaseLetters.contains(next) || CharacterSet.decimalDigits.contains(next) || next == "*" else { continue }
            let ended = current.dropLast().replacing(mark, with: "")
            if let end = ended.last, ".!?".contains(end) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        guard sentences.count > 1 else { return text }
        func words(_ sentence: String) -> Set<String> {
            Set(sentence.lowercased().replacing(mark, with: "").split { !$0.isLetter && !$0.isNumber }
                .map(String.init).filter { $0.count > 3 })
        }
        var kept: [String] = []
        for sentence in sentences {
            if let previous = kept.last {
                let a = words(previous), b = words(sentence)
                let shared = Double(a.intersection(b).count) / Double(max(min(a.count, b.count), 1))
                if shared >= 0.6, min(a.count, b.count) >= 3 {
                    // Keep the first wording, with the second's source mark.
                    if let mark = sentence.firstMatch(of: mark), !previous.contains("[[") {
                        kept[kept.count - 1] = previous + String(sentence[mark.range])
                    }
                    continue
                }
            }
            kept.append(sentence)
        }
        return kept.joined(separator: " ")
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
    /// A kind at a line's start, with more after it: ("> ", "howto", "Squeaky...").
    nonisolated(unsafe) private static let kindPrefix =
        /^(>\s*)?@?\s*(recipe|howto|compare|article|general)\s+(\S.*)$/
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

/// A checklist's or a table's box: the same width and corners as every other
/// box on the page, and none at all inside a section's band, which already is one.
private struct Panel: ViewModifier {
    let padding: CGFloat
    @Environment(\.inBand) private var inBand

    func body(content: Content) -> some View {
        if inBand {
            content
        } else {
            content
                .padding(.vertical, padding)
                .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 20, style: .continuous))
        }
    }
}

/// A row's side padding in its box, or none inside a band, where the rows
/// line up with the band's other text.
private struct BandInset: ViewModifier {
    let amount: CGFloat
    @Environment(\.inBand) private var inBand

    func body(content: Content) -> some View {
        content.padding(.horizontal, inBand ? 0 : amount)
    }
}

extension EnvironmentValues {
    /// Inside a section's tinted band.
    @Entry var inBand = false
}

/// How far down a long answer or summary the reader is: a short line above
/// the bar in the page's colour, filling as they scroll. Rounded ends, and
/// not there at all for a page that fits on screen.
struct ReadingLine: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tint.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, proxy.size.width * min(max(progress, 0), 1)))
                }
        }
        .frame(height: 3)
        .padding(.horizontal, 40)
        .opacity(progress > 0.01 ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: progress > 0.01)
        .accessibilityHidden(true)
    }

    /// Scrolled so far, 0 to 1; 0 for a page that fits.
    static func progress(_ geometry: ScrollGeometry) -> Double {
        let room = geometry.contentSize.height - geometry.containerSize.height
        guard room > 40 else { return 0 }
        return Double((geometry.contentOffset.y + geometry.contentInsets.top) / room)
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
