import SwiftUI

/// The page shrinks into a card at the top and its summary writes itself below.
struct SummaryView: View {
    let model: SummaryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageCard

                switch model.phase {
                case .reading:
                    StatusLine(text: "Reading the page")
                case .failed(let message):
                    Text(message)
                        .font(.body)
                        .foregroundStyle(Theme.secondaryInk)
                case .writing, .done:
                    if model.text.isEmpty {
                        StatusLine(text: "Writing")
                    } else {
                        MarkdownText(markdown: model.text)
                    }
                }

                if model.phase == .done {
                    Text([Self.credit(model.engine), model.note]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Theme.faintInk)
                }
            }
            // Full width and left-aligned even while only a short status line shows.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 40)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.panel)
        .presentationCornerRadius(28)
    }

    private static func credit(_ engine: String) -> String {
        switch engine {
        case "Claude": "Summarized by Claude"
        case "Apple Intelligence": "Summarized by Apple Intelligence, privately in Apple's cloud"
        default: "Summarized on this iPhone"
        }
    }

    private var pageCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let snapshot = model.snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 86, alignment: .top)
                } else {
                    Theme.raised.frame(width: 64, height: 86)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.edge))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                Text(model.host)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }
}

/// A quiet in-progress line whose trailing dots step on a timer.
struct StatusLine: View {
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 4
            Text(text + String(repeating: ".", count: step))
                .font(.body)
                .foregroundStyle(Theme.secondaryInk)
                .contentTransition(.identity)
        }
    }
}
