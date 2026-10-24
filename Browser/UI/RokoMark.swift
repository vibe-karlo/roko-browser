import SwiftUI

/// roko's mark, the Eclipse from the app icon: a disc with a smaller one cut
/// out off-centre (Scripts/make_alternate_icons.swift, Server/share's page).
nonisolated struct EclipseMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let unit = side / 600
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        path.addEllipse(in: CGRect(x: origin.x, y: origin.y, width: side, height: side))
        path.addEllipse(in: CGRect(x: origin.x + 244 * unit, y: origin.y + 150 * unit, width: 300 * unit, height: 300 * unit))
        return path
    }
}

/// The mark and the name, signing a summary or an answer: a screenshot of
/// one says where it came from.
struct RokoSignature: View {
    var body: some View {
        HStack(spacing: 6) {
            EclipseMark()
                .fill(Theme.ink, style: FillStyle(eoFill: true))
                .frame(width: 14, height: 14)
            Text("roko")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("roko")
    }
}
