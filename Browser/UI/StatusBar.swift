import SwiftUI
import UIKit

/// SwiftUI can't choose the status bar's text colour on its own, so the app's
/// root is wrapped once in this controller, which can. It shows black text over
/// a light page colour and white text over a dark one.
final class StatusBarController: UIViewController {
    private(set) static weak var shared: StatusBarController?

    var style: UIStatusBarStyle = .default {
        didSet {
            guard oldValue != style else { return }
            UIView.animate(withDuration: 0.2) { self.setNeedsStatusBarAppearanceUpdate() }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { style }

    /// Moves the window's SwiftUI content inside a wrapper. Sheets and safe
    /// areas carry on as before; only the status bar now asks the wrapper.
    fileprivate static func install(in window: UIWindow) {
        guard shared == nil, let content = window.rootViewController, !(content is StatusBarController) else { return }
        let wrapper = StatusBarController()
        window.rootViewController = wrapper
        wrapper.addChild(content)
        content.view.frame = wrapper.view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wrapper.view.addSubview(content.view)
        content.didMove(toParent: wrapper)
        shared = wrapper
    }
}

/// Put anywhere in the view tree: installs the wrapper once the window exists,
/// then keeps the status bar style in step with `style`.
struct StatusBarStyler: UIViewRepresentable {
    let style: UIStatusBarStyle

    func makeUIView(context: Context) -> Reader { Reader() }

    func updateUIView(_ reader: Reader, context: Context) {
        reader.style = style
        StatusBarController.shared?.style = style
    }

    final class Reader: UIView {
        var style: UIStatusBarStyle = .default

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            // Not during SwiftUI's own layout pass: swapping the root mid-pass is unsafe.
            DispatchQueue.main.async { [weak self] in
                StatusBarController.install(in: window)
                if let style = self?.style { StatusBarController.shared?.style = style }
            }
        }
    }
}

extension UIColor {
    /// Whether dark text reads better on it than light text.
    var isLight: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return true }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55
    }
}
