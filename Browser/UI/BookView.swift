import SwiftUI
import UIKit

/// Reader on an open iPhone Duo: the article as a book, a page each side of
/// the fold, turned with a real page curl. The same text as ReaderView, laid
/// out in pages by TextKit.
struct BookView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.fold) private var fold
    let model: ReaderModel
    @AppStorage("book.textSize") private var textSize: Double = 17

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                              height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            ZStack {
                Color(uiColor: BookStyle.paper)
                if let page = model.page, page.isArticle {
                    BookPages(page: page, host: model.host, size: size, textSize: textSize,
                              gutter: (fold?.width ?? 0) / 2 + 14)
                } else {
                    Text(model.page != nil ? "Reader Mode works on articles and posts."
                                           : model.failure ?? "Preparing the article")
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(Color(uiColor: BookStyle.faint))
                }
            }
            .overlay(alignment: .topTrailing) { controls.padding(.top, BookStyle.clockClearance) }
            .ignoresSafeArea()
        }
        .statusBarHidden(false)
    }

    /// Down the outer edge under the clock, as the system places a toolbar there.
    private var controls: some View {
        VStack(spacing: 6) {
            Button { browser.reader = nil } label: {
                Glyph(.close, size: 18, weight: 2).frame(width: 48, height: 48).contentShape(.rect)
            }
            .accessibilityLabel("Close")
            Spacer().frame(height: 10)
            Button { textSize = min(textSize + 1, 26) } label: {
                Text("A").font(.system(size: 21, weight: .medium, design: .serif)).frame(width: 48, height: 44).contentShape(.rect)
            }
            .accessibilityLabel("Larger text")
            Button { textSize = max(textSize - 1, 13) } label: {
                Text("A").font(.system(size: 14, weight: .medium, design: .serif)).frame(width: 48, height: 44).contentShape(.rect)
            }
            .accessibilityLabel("Smaller text")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: BookStyle.ink))
        // Centred under the clock.
        .padding(.trailing, 24)
    }
}

/// The paper and ink of a book, shared with Cook Mode.
enum BookStyle {
    static let paper = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1B1915) : UIColor(rgb: 0xF3ECDE) }
    static let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xDCD5C6) : UIColor(rgb: 0x2B2720) }
    static let faint = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x8F897B) : UIColor(rgb: 0x7C7566) }
    /// Clear of the clock and its status icons, which run down the outer edge.
    static let clockClearance: CGFloat = 108
    static let outerMargin: CGFloat = 80
    static let topMargin: CGFloat = 40
    static let bottomMargin: CGFloat = 54
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// The article cut into pages that fit. One layout runs through the whole book
/// and each page draws its part of it, so a word or a line split across a turn
/// breaks and justifies as it would on one page.
private struct BookLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let pages: [NSRange]
    let glyphs: [NSRange]

    init(page: ReadablePage, host: String, textSize: CGFloat, column: CGSize) {
        storage = NSTextStorage(attributedString: Self.attributed(page, host: host, textSize: textSize))
        storage.addLayoutManager(manager)
        var pages: [NSRange] = [], glyphs: [NSRange] = []
        var previous: NSTextContainer?
        let manager = manager, storage = storage
        // A heading never ends a page: it waits for its text on the next.
        func fit(_ container: NSTextContainer) -> NSRange {
            var range = manager.glyphRange(for: container)
            while NSMaxRange(range) < manager.numberOfGlyphs, let top = Self.strandedHeading(in: range, manager, storage) {
                container.size.height = top
                range = manager.glyphRange(for: container)
            }
            return range
        }
        // Never endless: a column too small to hold a line would add pages for ever.
        while pages.count < 2000 {
            let container = NSTextContainer(size: column)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            guard manager.glyphRange(for: container).length > 0 else { break }
            // Nor does a paragraph's last line start a page alone: the line before it comes too.
            if let previous, let before = glyphs.last, Self.opensWithLastLine(manager.glyphRange(for: container), manager, storage) {
                let top = manager.lineFragmentRect(forGlyphAt: NSMaxRange(before) - 1, effectiveRange: nil).minY
                if top > 0 {
                    previous.size.height = top
                    let range = fit(previous)
                    glyphs[glyphs.count - 1] = range
                    pages[pages.count - 1] = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
                }
            }
            let range = fit(container)
            pages.append(manager.characterRange(forGlyphRange: range, actualGlyphRange: nil))
            glyphs.append(range)
            previous = container
            if NSMaxRange(range) >= manager.numberOfGlyphs { break }
        }
        self.pages = pages
        self.glyphs = glyphs
    }

    /// Where the heading at the foot of this page starts, if there is one with text above it.
    private static func strandedHeading(in range: NSRange, _ manager: NSLayoutManager, _ storage: NSTextStorage) -> CGFloat? {
        let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        let last = (storage.string as NSString).paragraphRange(for: NSRange(location: NSMaxRange(characters) - 1, length: 0))
        guard last.location > characters.location,
              storage.attribute(headingKey, at: last.location, effectiveRange: nil) != nil else { return nil }
        return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: last.location), effectiveRange: nil).minY
    }

    /// Whether this page's first line is all that's left of a paragraph from the page before.
    private static func opensWithLastLine(_ range: NSRange, _ manager: NSLayoutManager, _ storage: NSTextStorage) -> Bool {
        var line = NSRange()
        manager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: &line)
        let characters = manager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: characters.location, length: 0))
        return paragraph.location < characters.location && NSMaxRange(paragraph) <= NSMaxRange(characters)
    }

    private static let headingKey = NSAttributedString.Key("roko.book.heading")

    func index(containing offset: Int) -> Int {
        pages.firstIndex { NSLocationInRange(offset, $0) } ?? 0
    }

    private static func attributed(_ page: ReadablePage, host: String, textSize: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func serif(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size)
        }
        func add(_ string: String, font: UIFont, color: UIColor, after: CGFloat, before: CGFloat = 0, body: Bool = false, heading: Bool = false) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            style.paragraphSpacingBefore = before
            style.lineHeightMultiple = body ? 1.22 : 1.08
            style.alignment = body ? .justified : .natural
            style.hyphenationFactor = body ? 1 : 0
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if heading { attributes[headingKey] = true }
            out.append(NSAttributedString(string: string + "\n", attributes: attributes))
        }
        add(page.title, font: serif(textSize * 1.6, .semibold), color: BookStyle.ink, after: 6)
        add(page.site.isEmpty ? host : page.site, font: serif(textSize * 0.8, .regular), color: BookStyle.faint, after: textSize * 1.4)
        for block in page.text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !block.isEmpty {
            // Readability's blocks carry no level here: short and unfinished, or a short question, reads as a heading.
            let heading = block.count < 70 && !".!:;\u{201D}\"".contains(block.last!)
            if heading {
                add(block, font: serif(textSize * 1.08, .semibold), color: BookStyle.ink, after: 4, before: textSize * 0.6, heading: true)
            } else {
                add(block, font: serif(textSize, .regular), color: BookStyle.ink, after: textSize * 0.55, body: true)
            }
        }
        return out
    }
}

private struct BookPages: UIViewControllerRepresentable {
    let page: ReadablePage
    let host: String
    let size: CGSize
    let textSize: Double
    let gutter: CGFloat

    func makeUIViewController(context: Context) -> UIPageViewController {
        let book = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                        options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.mid.rawValue)])
        book.isDoubleSided = true
        book.dataSource = context.coordinator
        book.delegate = context.coordinator
        book.view.backgroundColor = BookStyle.paper
        return book
    }

    func updateUIViewController(_ book: UIPageViewController, context: Context) {
        context.coordinator.lay(out: self, in: book)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private var layout: BookLayout?
        private var laidOut: (CGSize, Double, CGFloat, String)?
        private var pageSize = CGSize.zero
        private var outer: CGFloat = 0, inner: CGFloat = 0
        /// Where the reader is in the text, kept when the size changes the pages.
        private var offset = 0

        func lay(out spec: BookPages, in book: UIPageViewController) {
            if let done = laidOut, done.0 == spec.size, done.1 == spec.textSize, done.2 == spec.gutter, done.3 == spec.page.title { return }
            guard spec.size.width > 0, spec.size.height > 0 else { return }
            laidOut = (spec.size, spec.textSize, spec.gutter, spec.page.title)
            outer = BookStyle.outerMargin
            inner = spec.gutter
            pageSize = CGSize(width: spec.size.width / 2, height: spec.size.height)
            let column = CGSize(width: pageSize.width - outer - inner,
                                height: pageSize.height - BookStyle.topMargin - BookStyle.bottomMargin)
            let fresh = BookLayout(page: spec.page, host: spec.host, textSize: spec.textSize, column: column)
            layout = fresh
            let start = fresh.index(containing: offset) / 2 * 2
            book.setViewControllers([leaf(start), leaf(start + 1)], direction: .forward, animated: false)
        }

        /// One side of a leaf. A last page with nothing opposite gets a blank.
        private func leaf(_ index: Int) -> BookLeaf {
            BookLeaf(index: index, layout: layout, leftSide: index % 2 == 0, outer: outer, inner: inner)
        }

        private var count: Int {
            let pages = layout?.pages.count ?? 0
            return pages + pages % 2
        }

        func pageViewController(_ book: UIPageViewController, viewControllerBefore current: UIViewController) -> UIViewController? {
            guard let index = (current as? BookLeaf)?.index, index > 0 else { return nil }
            return leaf(index - 1)
        }

        func pageViewController(_ book: UIPageViewController, viewControllerAfter current: UIViewController) -> UIViewController? {
            guard let index = (current as? BookLeaf)?.index, index + 1 < count else { return nil }
            return leaf(index + 1)
        }

        func pageViewController(_ book: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            .mid
        }

        func pageViewController(_ book: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let first = book.viewControllers?.first as? BookLeaf, let layout,
                  first.index < layout.pages.count else { return }
            offset = layout.pages[first.index].location
        }
    }
}

/// One page: its text, its number at the foot, and the shade of the spine.
private final class BookLeaf: UIViewController {
    let index: Int
    private let layout: BookLayout?
    private let leftSide: Bool
    private let outer: CGFloat
    private let inner: CGFloat

    init(index: Int, layout: BookLayout?, leftSide: Bool, outer: CGFloat, inner: CGFloat) {
        self.index = index
        self.layout = layout
        self.leftSide = leftSide
        self.outer = outer
        self.inner = inner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BookStyle.paper
        let leading = leftSide ? outer : inner
        let trailing = leftSide ? inner : outer

        let shade = SpineShade(fromRight: leftSide)
        shade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.topAnchor.constraint(equalTo: view.topAnchor),
            shade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            shade.widthAnchor.constraint(equalToConstant: 34),
            leftSide ? shade.trailingAnchor.constraint(equalTo: view.trailingAnchor)
                     : shade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ])

        guard let layout, index < layout.pages.count else { return }
        let body = BookText(layout: layout, index: index)
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)

        let number = UILabel()
        number.text = "\(index + 1)"
        number.font = .systemFont(ofSize: 12, weight: .regular)
        number.textColor = BookStyle.faint
        number.textAlignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(number)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: BookStyle.topMargin),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -BookStyle.bottomMargin),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -trailing),
            number.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            number.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
        ])
    }
}

/// A page's part of the book's one layout, drawn where it was measured.
private final class BookText: UIView {
    private let layout: BookLayout
    private let glyphs: NSRange

    init(layout: BookLayout, index: Int) {
        self.layout = layout
        glyphs = layout.glyphs[index]
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = (layout.storage.string as NSString).substring(with: layout.pages[index])
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func draw(_ rect: CGRect) {
        layout.manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }
}

/// The page falling away into the spine: light from one side, no hard edge.
private final class SpineShade: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(fromRight: Bool) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let gradient = layer as? CAGradientLayer
        gradient?.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                            UIColor.black.withAlphaComponent(0.02).cgColor,
                            UIColor.black.withAlphaComponent(0.085).cgColor]
        gradient?.locations = [0, 0.65, 1]
        gradient?.startPoint = CGPoint(x: fromRight ? 0 : 1, y: 0.5)
        gradient?.endPoint = CGPoint(x: fromRight ? 1 : 0, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }
}
