import SwiftUI

/// Files from pages, newest first: each one's progress, a pause or a resume,
/// and a tap to open what's finished. They're in the Files app too.
struct DownloadsSheet: View {
    @Environment(BrowserModel.self) private var browser
    private var downloads: Downloads { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Also in Files, under On My iPhone, roko.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                if downloads.items.contains(where: { $0.state == .done || $0.state == .failed }) {
                    Button("Clear") { downloads.clearFinished() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
            }
            .padding(.horizontal, 20)

            if downloads.items.isEmpty {
                Text("Nothing downloaded yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .background(Theme.raised, in: .rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.edge))
                    .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 24)
        .foregroundStyle(Theme.ink)
        .animation(.snappy(duration: 0.25), value: downloads.items)
    }
}

private struct DownloadRow: View {
    let item: Downloads.Item
    private var downloads: Downloads { .shared }

    var body: some View {
        HStack(spacing: 14) {
            Button { if item.state == .done { downloads.open(item) } } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.state == .running || item.state == .paused {
                        ProgressTrack(fraction: item.fraction, paused: item.state == .paused)
                    }
                    Text(detail)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(RowButtonStyle())

            switch item.state {
            case .running: control(.pause, "Pause") { downloads.pause(item) }
            case .paused: control(.play, "Resume") { downloads.resume(item) }
            case .failed: control(.reload, "Try again") { downloads.retry(item) }
            case .done: EmptyView()
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .contextMenu {
            if item.state == .done {
                Button("Open") { downloads.open(item) }
                ShareLink(item: downloads.file(for: item)) { Text("Share") }
            }
            Button(item.state == .done ? "Remove and Delete File" : "Cancel and Remove", role: .destructive) {
                downloads.remove(item)
            }
        }
    }

    private var detail: String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch item.state {
        case .running:
            return item.total > 0 ? "\(size(item.received)) of \(size(item.total))" : size(item.received)
        case .paused:
            return item.total > 0 ? "Paused at \(size(item.received)) of \(size(item.total))" : "Paused"
        case .failed:
            return "Didn't finish"
        case .done:
            let when = item.startedAt.formatted(.relative(presentation: .named))
            return item.total > 0 ? "\(size(item.total)), \(when)" : when
        }
    }

    private func control(_ glyph: Glyph.Kind, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: 20)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel(label)
    }
}

/// How far a file has got: a rounded track, filled by width so its ends stay round.
private struct ProgressTrack: View {
    let fraction: Double
    let paused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.edge)
                Capsule()
                    .fill(paused ? Theme.faintInk : Theme.ink)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}
