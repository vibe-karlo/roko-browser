import SwiftUI

/// The browser's own icon set, drawn on a 20-point grid with round caps. The
/// house detail is the chamfer: every box has its top-right corner cut at 45°.
struct Glyph: View {
    nonisolated enum Kind {
        case tabs, plus, chevronUp, back, forward, close, search, pin, history, tab,
             openLink, summarize, browse, share, reload, blocking, settings, copy, privacy, popup, equals, link, textSize, desktop, reader
    }

    let kind: Kind
    var size: CGFloat = 20
    var weight: CGFloat = 1.6

    init(_ kind: Kind, size: CGFloat = 20, weight: CGFloat = 1.6) {
        self.kind = kind
        self.size = size
        self.weight = weight
    }

    var body: some View {
        GlyphShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: weight * size / 20, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private nonisolated struct GlyphShape: Shape {
    let kind: Glyph.Kind

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 20
        var path = Path()
        draw(&path)
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private func draw(_ p: inout Path) {
        switch kind {
        case .tabs:
            p.chamferedBox(x: 3, y: 6, width: 11, height: 11)
            p.lines([(6, 3), (14, 3), (17, 6), (17, 14)])
        case .tab, .copy:
            if kind == .copy {
                p.chamferedBox(x: 3, y: 6, width: 10, height: 11)
                p.lines([(7, 3), (14, 3), (17, 6), (17, 13)])
            } else {
                p.chamferedBox(x: 4, y: 4, width: 12, height: 12)
            }
        case .plus:
            p.lines([(10, 4), (10, 16)])
            p.lines([(4, 10), (16, 10)])
        case .chevronUp:
            p.lines([(5, 12.5), (10, 7.5), (15, 12.5)])
        case .back:
            p.lines([(12.5, 5), (7.5, 10), (12.5, 15)])
        case .forward:
            p.lines([(7.5, 5), (12.5, 10), (7.5, 15)])
        case .close:
            p.lines([(5.5, 5.5), (14.5, 14.5)])
            p.lines([(14.5, 5.5), (5.5, 14.5)])
        case .search:
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 10, height: 10))
            p.lines([(12.2, 12.2), (16.5, 16.5)])
        case .pin:
            p.chamferedBox(x: 5, y: 3, width: 10, height: 9)
            p.lines([(10, 12), (10, 17.5)])
        case .history:
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 13, height: 13))
            p.lines([(10, 6.5), (10, 10), (12.8, 11.6)])
        case .openLink:
            p.lines([(6, 14), (14, 6)])
            p.lines([(8.5, 6), (14, 6), (14, 11.5)])
        case .summarize:
            p.lines([(4, 6), (16, 6)])
            p.lines([(4, 10), (13, 10)])
            p.lines([(4, 14), (9, 14)])
        case .browse:
            p.chamferedBox(x: 3, y: 6, width: 10, height: 11)
            p.lines([(9.5, 10.5), (17, 3)])
            p.lines([(12.5, 3), (17, 3), (17, 7.5)])
        case .share:
            p.lines([(6, 9), (5, 9), (5, 16.5), (15, 16.5), (15, 9), (14, 9)])
            p.lines([(10, 12), (10, 3)])
            p.lines([(7, 6), (10, 3), (13, 6)])
        case .reload:
            // A circle open at the top right, with the arrowhead sitting exactly on
            // the arc's end and pointing along it (clockwise, into the gap).
            var arc: [(CGFloat, CGFloat)] = []
            for step in 0...36 {
                let angle = (-30 + 300 * CGFloat(step) / 36) * .pi / 180
                arc.append((10 + 6 * cos(angle), 10.5 + 6 * sin(angle)))
            }
            p.lines(arc)
            p.lines([(7.4, 2.2), (10, 4.5), (7.4, 6.8)])
        case .blocking:
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 13, height: 13))
            p.lines([(5.5, 14.5), (14.5, 5.5)])
        case .settings:
            p.lines([(4, 7), (16, 7)])
            p.lines([(4, 13), (16, 13)])
            p.addEllipse(in: CGRect(x: 10.5, y: 5, width: 4, height: 4))
            p.addEllipse(in: CGRect(x: 5.5, y: 11, width: 4, height: 4))
        case .link:
            // Two rounded links on the diagonal, crossing only at their tips.
            for (cx, cy) in [(CGFloat(7.2), CGFloat(12.8)), (12.8, 7.2)] {
                let turn = CGAffineTransform(translationX: cx, y: cy).rotated(by: -.pi / 4).translatedBy(x: -cx, y: -cy)
                p.addRoundedRect(in: CGRect(x: cx - 5.25, y: cy - 2.75, width: 10.5, height: 5.5),
                                 cornerSize: CGSize(width: 2.75, height: 2.75), transform: turn)
            }
        case .textSize:
            // A small and a large A.
            p.lines([(2.5, 16), (5.5, 9), (8.5, 16)])
            p.lines([(3.8, 13.2), (7.2, 13.2)])
            p.lines([(9, 16), (13.25, 5), (17.5, 16)])
            p.lines([(10.9, 12), (15.6, 12)])
        case .desktop:
            p.chamferedBox(x: 4, y: 4.5, width: 12, height: 8.5)
            p.lines([(2.5, 15.5), (17.5, 15.5)])
        case .reader:
            p.chamferedBox(x: 4, y: 3, width: 12, height: 14)
            p.lines([(7, 7.5), (13, 7.5)])
            p.lines([(7, 10.5), (13, 10.5)])
            p.lines([(7, 13.5), (11, 13.5)])
        case .equals:
            p.lines([(4.5, 7.5), (15.5, 7.5)])
            p.lines([(4.5, 12.5), (15.5, 12.5)])
        case .popup:
            // A dialog: the house chamfered box with a title strip.
            p.chamferedBox(x: 3, y: 4, width: 14, height: 12)
            p.lines([(3, 8), (17, 8)])
            p.lines([(6.5, 11.5), (12, 11.5)])
        case .privacy:
            p.addEllipse(in: CGRect(x: 2.5, y: 8, width: 6, height: 6))
            p.addEllipse(in: CGRect(x: 11.5, y: 8, width: 6, height: 6))
            p.lines([(8.5, 10.5), (11.5, 10.5)])
        }
    }
}

private nonisolated extension Path {
    mutating func lines(_ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { addLine(to: CGPoint(x: point.0, y: point.1)) }
    }

    mutating func chamferedBox(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cut: CGFloat = 3) {
        lines([(x, y), (x + width - cut, y), (x + width, y + cut), (x + width, y + height), (x, y + height)])
        closeSubpath()
    }
}
