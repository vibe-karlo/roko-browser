import SwiftUI

/// The iPhone Duo's fold: the line where the inner screen bends, which
/// nothing of roko's should sit across. Nil on every other iPhone, and on
/// the Duo while it's shut.
extension EnvironmentValues {
    /// In global coordinates.
    @Entry var fold: CGRect? = nil
}

extension View {
    /// Reads the fold off the screen and hands it down.
    func readsFold() -> some View { modifier(FoldReader()) }

    /// Keeps a control to one half of an open Duo, the roomier one, rather
    /// than straddling the fold. Unchanged anywhere there's no fold.
    func keepsOffFold() -> some View { modifier(OffFold()) }
}

private struct OffFold: ViewModifier {
    @Environment(\.fold) private var fold
    @State private var room: CGRect = .zero

    func body(content: Content) -> some View {
        let side = half
        content
            .frame(width: side?.width)
            .padding(.leading, side?.minX ?? 0)
            .frame(maxWidth: .infinity, alignment: side == nil ? .center : .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { room = $0 }
    }

    /// The wider half beside an upright fold, in this view's own space.
    private var half: CGRect? {
        guard let fold, fold.height > fold.width, room.width > 0,
              fold.minX > room.minX, fold.maxX < room.maxX else { return nil }
        let before = fold.minX - room.minX
        let after = room.maxX - fold.maxX
        return before >= after
            ? CGRect(x: 0, y: 0, width: before, height: room.height)
            : CGRect(x: fold.maxX - room.minX, y: 0, width: after, height: room.height)
    }
}

private struct FoldReader: ViewModifier {
    @State private var fold: CGRect?
    /// Bumped as the hinge moves: the fold's region is read again then.
    @State private var hinge = 0

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .background {
                    GeometryReader { proxy in
                        // The region arrives a moment after the screen does, so
                        // it's asked for a few times before settling on none.
                        Color.clear.task(id: [hinge, Int(proxy.size.width), Int(proxy.size.height)]) {
                            for _ in 0..<12 {
                                let found = Self.fold(in: proxy)
                                if fold != found { fold = found }
                                if found != nil || Task.isCancelled { return }
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                        }
                    }
                }
                .onHingeChange { _, _ in hinge += 1 }
                .environment(\.fold, fold)
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private static func fold(in proxy: GeometryProxy) -> CGRect? {
        // Lying flat the fold counts as inactive, but it's still where the
        // screen bends: kept to, so nothing jumps as the hinge moves.
        guard let region = proxy.reservedRegions(kind: .division, options: .includeInactive).first,
              region.frame.intersects(CGRect(origin: .zero, size: proxy.size)) else { return nil }
        let origin = proxy.frame(in: .global).origin
        return region.frame.offsetBy(dx: origin.x, dy: origin.y)
    }
}
