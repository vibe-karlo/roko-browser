import SwiftUI

/// The launcher opens out of the bar: the bar's middle capsule is the same
/// shape as the launcher's field, matched across the two, so opening it the
/// capsule widens and rises into the field, and closing it comes back down.
/// One namespace for the whole app, held here.
struct LauncherSpace<Content: View>: View {
    @Namespace private var space
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.launcherSpace, space)
    }
}

extension EnvironmentValues {
    @Entry var launcherSpace: Namespace.ID? = nil
}

extension View {
    /// The shape that becomes the launcher's field (or comes from it).
    @ViewBuilder
    func launcherMorph(_ space: Namespace.ID?, id: String = "launcher") -> some View {
        if let space { matchedGeometryEffect(id: id, in: space) } else { self }
    }
}

extension Animation {
    /// The bar opening into the launcher and closing back into it.
    static let launcher = Animation.spring(duration: 0.42, bounce: 0.08)
}
