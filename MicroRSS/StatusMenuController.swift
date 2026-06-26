import AppKit
import WebKit

@MainActor
final class StatusMenuController: NSObject {
    private let store: FeedStore
    private let service: RSSService
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var storiesByFeed: [UUID: [FeedStory]] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var preferencesWindowController: PreferencesWindowController?
    private var previewWindows: [NSWindowController] = []
    private var storeObserverID: UUID?

    init(store: FeedStore, service: RSSService) {
        self.store = store
        self.service = service
        super.init()
        configureStatusItem()
        storeObserverID = store.observe { [weak self] in
            self?.rescheduleRefresh()
            self?.rebuildMenu()
        }
        rescheduleRefresh()
        rebuildMenu()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "RSS"
        statusItem.button?.toolTip = "MicroRSS"
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if store.feeds.isEmpty {
            let empty = NSMenuItem(title: "No feeds configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for feed in store.feeds {
                let item = NSMenuItem(title: feed.displayName, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                let stories = storiesByFeed[feed.id] ?? []

                if stories.isEmpty {
                    let empty = NSMenuItem(title: "No stories loaded", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                } else {
                    for story in stories.prefix(20) {
                        submenu.addItem(storyMenuItem(story))
                    }
                }

                submenu.addItem(.separator())
                submenu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshFeedFromMenu(_:)), keyEquivalent: ""))
                submenu.items.last?.target = self
                submenu.items.last?.representedObject = feed.id
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh All", action: #selector(refreshAllFromMenu), keyEquivalent: "r"))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "Quit MicroRSS", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    private func storyMenuItem(_ story: FeedStory) -> NSMenuItem {
        let item = NSMenuItem(title: story.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let feed = store.feeds.first { $0.id == story.sourceFeedID }

        let preview = NSMenuItem()
        preview.view = StoryPreviewMenuView(story: story, feed: feed)
        submenu.addItem(preview)

        let previewWindow = NSMenuItem(title: "Open Preview Window", action: #selector(openPreview(_:)), keyEquivalent: "")
        previewWindow.target = self
        if let feed {
            previewWindow.representedObject = FeedStoryContext(story: story, feed: feed)
        } else {
            previewWindow.representedObject = story
        }
        previewWindow.isEnabled = story.link != nil
        submenu.addItem(previewWindow)

        let open = NSMenuItem(title: "Open in Browser", action: #selector(openStory(_:)), keyEquivalent: "")
        open.target = self
        if let feed {
            open.representedObject = FeedStoryContext(story: story, feed: feed)
        } else {
            open.representedObject = story
        }
        open.isEnabled = story.link != nil
        submenu.addItem(open)

        item.submenu = submenu
        return item
    }

    private func rescheduleRefresh() {
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        for feed in store.feeds {
            refreshTasks[feed.id] = Task { [weak self] in
                await self?.refreshLoop(feedID: feed.id)
            }
        }
    }

    private func refreshLoop(feedID: UUID) async {
        while !Task.isCancelled {
            await refreshFeed(id: feedID)
            let minutes = store.feeds.first(where: { $0.id == feedID })?.refreshMinutes ?? store.globalRefreshMinutes
            let seconds = max(1, minutes) * 60
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        }
    }

    @MainActor
    private func refreshFeed(id: UUID) async {
        guard let feed = store.feeds.first(where: { $0.id == id }) else { return }
        do {
            let (stories, metadata) = try await service.fetch(feed: feed)
            storiesByFeed[id] = stories
            updateFeedMetadata(feed: feed, metadata: metadata)
            rebuildMenu()
        } catch {
            storiesByFeed[id] = []
            rebuildMenu()
        }
    }

    @MainActor
    private func updateFeedMetadata(feed: Feed, metadata: FeedMetadata) {
        var updated = feed
        var changed = false

        if updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let title = metadata.title, !title.isEmpty {
            updated.name = title
            changed = true
        }

        if updated.iconURL == nil {
            updated.iconURL = metadata.iconURL ?? faviconURL(for: metadata.siteURL ?? feed.url)
            changed = updated.iconURL != nil
        }

        if changed {
            store.updateFeed(updated)
        }
    }

    private func faviconURL(for siteURL: URL) -> URL? {
        guard let scheme = siteURL.scheme, let host = siteURL.host(percentEncoded: false) else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    @objc private func refreshAllFromMenu() {
        for feed in store.feeds {
            Task { await refreshFeed(id: feed.id) }
        }
    }

    @objc private func refreshFeedFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task { await refreshFeed(id: id) }
    }

    @objc private func openSettings() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(store: store)
        }
        if preferencesWindowController?.window?.isVisible == false {
            preferencesWindowController?.window?.center()
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreview(_ sender: NSMenuItem) {
        let controller: PreviewWindowController
        if let context = sender.representedObject as? FeedStoryContext {
            controller = PreviewWindowController(story: context.story, feed: context.feed)
        } else if let story = sender.representedObject as? FeedStory {
            controller = PreviewWindowController(story: story)
        } else {
            return
        }
        previewWindows.append(controller)
        controller.window?.delegate = self
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openStory(_ sender: NSMenuItem) {
        if let context = sender.representedObject as? FeedStoryContext,
           let url = Self.storyURL(for: context.story, feed: context.feed) {
            NSWorkspace.shared.open(url)
        } else if let story = sender.representedObject as? FeedStory, let url = story.link {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    static func storyURL(for story: FeedStory, feed: Feed) -> URL? {
        guard let link = story.link else { return nil }
        return link.appendingMissingQueryItems(from: feed.url)
    }

    static func storyRequest(for story: FeedStory, feed: Feed?) -> URLRequest? {
        guard let url = feed.flatMap({ storyURL(for: story, feed: $0) }) ?? story.link else { return nil }
        var request = URLRequest(url: url)
        if let feed {
            request.setValue(feed.url.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }
}

extension StatusMenuController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        previewWindows.removeAll { $0.window === notification.object as? NSWindow }
    }
}

private final class StoryPreviewMenuView: NSView {
    private static let previewSize = NSSize(width: 640, height: 420)

    private let story: FeedStory
    private let feed: Feed?
    private var webView: WKWebView?
    private var didStartLoading = false

    init(story: FeedStory, feed: Feed?) {
        self.story = story
        self.feed = feed
        super.init(frame: NSRect(origin: .zero, size: Self.previewSize))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        Self.previewSize
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        guard webView == nil else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        "Loading preview...".draw(
            in: bounds.insetBy(dx: 24, dy: 190),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didStartLoading else { return }

        didStartLoading = true
        let webView = WKWebView(frame: bounds, configuration: WebPreviewSession.makeConfiguration())
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        self.webView = webView

        if let request = StatusMenuController.storyRequest(for: story, feed: feed) {
            WebPreviewSession.load(request, in: webView, feed: feed)
        } else {
            webView.loadHTMLString(Self.summaryHTML(for: story), baseURL: nil)
        }
    }

    private static func summaryHTML(for story: FeedStory) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><style>body{font: -apple-system-body; margin: 24px;} h1{font: -apple-system-title2;}</style></head>
        <body><h1>\(story.title.escapedHTML)</h1><div>\(story.summary)</div></body>
        </html>
        """
    }
}

@MainActor
enum WebPreviewSession {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }

    static func load(_ request: URLRequest, in webView: WKWebView, feed: Feed?) {
        let cookies = cookiesForPreview(request: request, feed: feed)
        setCookies(cookies, in: webView.configuration.websiteDataStore.httpCookieStore) {
            webView.load(request)
        }
    }

    private static func cookiesForPreview(request: URLRequest, feed: Feed?) -> [HTTPCookie] {
        let urls = [request.url, feed?.url].compactMap { $0 }
        var seenKeys: Set<String> = []
        var cookies: [HTTPCookie] = []

        for url in urls {
            for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
                let key = "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
                if seenKeys.insert(key).inserted {
                    cookies.append(cookie)
                }
            }
        }

        return cookies
    }

    private static func setCookies(_ cookies: [HTTPCookie], in store: WKHTTPCookieStore, completion: @escaping () -> Void) {
        guard let cookie = cookies.first else {
            completion()
            return
        }

        store.setCookie(cookie) {
            setCookies(Array(cookies.dropFirst()), in: store, completion: completion)
        }
    }
}


private extension URL {
    func appendingMissingQueryItems(from sourceURL: URL) -> URL {
        guard let sourceItems = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems,
              !sourceItems.isEmpty,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }

        var items = components.queryItems ?? []
        let existingNames = Set(items.map(\.name))
        let missingItems = sourceItems.filter { !existingNames.contains($0.name) }
        guard !missingItems.isEmpty else { return self }
        items.append(contentsOf: missingItems)
        components.queryItems = items
        return components.url ?? self
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
