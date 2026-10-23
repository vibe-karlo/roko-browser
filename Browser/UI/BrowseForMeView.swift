import SwiftUI

/// A page written for one question, from several sources read on your behalf.
struct BrowseForMeView: View {
    @Environment(BrowserModel.self) private var browser
    let model: BrowseForMeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Glyph(.browse, size: 18).foregroundStyle(Theme.secondaryInk)
                    Text(model.query)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(2)
                }

                switch model.phase {
                case .searching(let query):
                    StatusLine(text: query.isEmpty ? "Searching" : "Searching \u{201C}\(query)\u{201D}")
                case .reading(let count):
                    StatusLine(text: "Reading \(count) pages")
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.secondaryInk)
                case .writing, .done:
                    MarkdownText(markdown: model.text)
                }

                if !model.sources.isEmpty {
                    sources
                }

                if model.phase == .done, !model.engine.isEmpty {
                    Text(model.engine == "Claude" ? "Written by Claude"
                         : model.engine == "Apple Intelligence" ? "Written by Apple Intelligence, privately in Apple's cloud"
                         : "Written on this iPhone")
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
        .presentationDetents([.large])
        .presentationBackground(Theme.panel)
        .presentationCornerRadius(28)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Read \(model.sources.count) \(model.sources.count == 1 ? "source" : "sources")")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.faintInk)
                .padding(.bottom, 6)

            ForEach(model.sources) { source in
                Button {
                    browser.browseForMe = nil
                    browser.open(source.url, inNewTab: true)
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(host: source.url.displayHost, size: 16)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(source.url.displayHost)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Glyph(.openLink, size: 14).foregroundStyle(Theme.faintInk)
                    }
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}
