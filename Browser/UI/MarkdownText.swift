import SwiftUI

/// Renders the small Markdown subset the AI features write: "# " title,
/// "## " section headings, "- " lines and paragraphs, with inline emphasis and links.
struct MarkdownText: View {
    let markdown: String

    private enum Block: Hashable {
        case title(String), heading(String), bullet(String), paragraph(String)
    }

    private var blocks: [Block] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .title(let text):
                    Text(inline(text))
                        .font(.system(.title2, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.bottom, 2)
                case .heading(let text):
                    Text(inline(text))
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, index == 0 ? 0 : 10)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Capsule()
                            .fill(Theme.faintInk)
                            .frame(width: 8, height: 2)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        Text(inline(text))
                    }
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .lineSpacing(3)
        .tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
