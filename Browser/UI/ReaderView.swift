import SwiftUI
import WebKit

/// The article alone: Readability's extracted text set for reading.
@Observable
final class ReaderModel: Identifiable {
    let host: String
    private(set) var page: ReadablePage?
    private(set) var failure: String?

    init(host: String) {
        self.host = host
    }

    func load(from webView: WKWebView) async {
        do {
            page = try await PageReader.read(webView)
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct ReaderView: View {
    let model: ReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let page = model.page, !page.isArticle {
                    Text("Nothing to read here")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Reader Mode works on articles and posts. This page looks like a homepage or a list of links.")
                        .foregroundStyle(Theme.secondaryInk)
                } else if let page = model.page {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.title)
                            .font(.system(.title, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(page.site.isEmpty ? model.host : page.site)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .padding(.bottom, 6)

                    ForEach(Array(paragraphs(page.text).enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 19))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                } else if let failure = model.failure {
                    Text(failure).foregroundStyle(Theme.secondaryInk)
                } else {
                    StatusLine(text: "Preparing the article")
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 60)
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.panel)
        .presentationCornerRadius(28)
    }

    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
