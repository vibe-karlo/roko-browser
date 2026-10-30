import UIKit
import WebKit

/// A touched-and-held link's page in the menu's preview, live: it loads
/// there, and the same web view becomes the tab when it's opened.
final class LinkPreview: UIViewController {
    private let page: BrowserTab

    init(tab: BrowserTab) {
        self.page = tab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let screen = view.window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        preferredContentSize = CGSize(width: screen.width, height: (screen.height * 0.62).rounded())
        guard let webView = page.webView else { return }
        webView.removeFromSuperview()
        webView.obscuredContentInsets = .zero
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
