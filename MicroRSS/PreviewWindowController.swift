import AppKit
import WebKit

@MainActor
final class PreviewWindowController: NSWindowController {
    private let story: FeedStory
    private let webView = WKWebView()

    init(story: FeedStory) {
        self.story = story
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = story.title
        super.init(window: window)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        if let link = story.link {
            webView.load(URLRequest(url: link))
        } else {
            let html = """
            <!doctype html>
            <html>
            <head><meta charset="utf-8"><style>body{font: -apple-system-body; margin: 32px; max-width: 760px;} h1{font: -apple-system-title1;} </style></head>
            <body><h1>\(story.title.escapedHTML)</h1><div>\(story.summary)</div></body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

private extension String {
    var escapedHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
