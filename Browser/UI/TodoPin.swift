import SwiftData
import SwiftUI

/// With your pins while anything is due today (or overdue): the to-do icon
/// with how many are left as a notification number. Tapping it opens the
/// list. Nothing due, and it isn't there at all.
struct TodoPin<Label: View>: View {
    @Environment(BrowserModel.self) private var browser
    @Query private var todos: [Todo]
    let size: CGFloat
    /// How it sits in the row it joins (the pins' own frame and button style).
    @ViewBuilder let frame: (TodoIcon) -> Label

    init(size: CGFloat, @ViewBuilder frame: @escaping (TodoIcon) -> Label) {
        self.size = size
        self.frame = frame
    }

    var body: some View {
        let left = todos.filter(\.isDueNow).count
        if left > 0 {
            Button { browser.panel = .todos } label: {
                frame(TodoIcon(left: left, size: size))
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("To-do, \(left) left for today")
        }
    }
}

/// The checklist icon, at a pin's size, with the count on its top-right
/// corner in roko's orange.
struct TodoIcon: View {
    let left: Int
    let size: CGFloat

    var body: some View {
        CountedGlyph(glyph: .todo, count: left, size: size)
    }
}

/// A glyph at a pin's size with a count on its top-right corner, in roko's
/// orange: To-do's checklist, Shopping's basket.
struct CountedGlyph: View {
    let glyph: Glyph.Kind
    let count: Int
    let size: CGFloat

    var body: some View {
        Glyph(glyph, size: size * 0.86)
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: size * 0.38, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, count > 9 ? size * 0.12 : 0)
                    .frame(minWidth: size * 0.56, minHeight: size * 0.56)
                    .background(Theme.accent, in: .capsule)
                    // Its own edge in the surface's colour, so it reads apart from the icon.
                    .overlay(Capsule().strokeBorder(Theme.panel, lineWidth: size * 0.06))
                    .fixedSize()
                    .offset(x: size * 0.22, y: -size * 0.2)
            }
            .animation(.snappy, value: count)
    }
}
