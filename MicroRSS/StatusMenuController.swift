import AppKit
import WebKit

@MainActor
final class StatusMenuController: NSObject {
    private let store: FeedStore
    private let service: RSSService
    private let iconCache = FeedIconCache()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var storiesByFeed: [UUID: [FeedStory]] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var preferencesWindowController: PreferencesWindowController?
    private var previewWindows: [NSWindowController] = []
    private var storeObserverID: UUID?
    private var updatesPaused = false

    init(store: FeedStore, service: RSSService) {
        self.store = store
        self.service = service
        super.init()
        iconCache.didUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        configureStatusItem()
        storeObserverID = store.observe { [weak self] in
            self?.rescheduleRefresh()
            self?.rebuildMenu()
        }
        rescheduleRefresh()
        rebuildMenu()
    }

    private func configureStatusItem() {
        statusItem.button?.toolTip = "MicroRSS"
        statusItem.menu = menu
        updateStatusItem()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        updateStatusItem()

        menu.addItem(generalMenuItem())
        menu.addItem(.separator())

        let pause = NSMenuItem(title: updatesPaused ? "Resume Updates" : "Pause Updates", action: #selector(toggleUpdatesPaused), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        addGlobalMenuItems()
        menu.addItem(.separator())

        if store.feeds.isEmpty {
            let empty = NSMenuItem(title: "No feeds configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for feed in store.feeds {
                let stories = storiesByFeed[feed.id] ?? []
                let unreadCount = store.unreadStories(in: stories).count
                let item = NSMenuItem(title: feedMenuTitle(feed: feed, unreadCount: unreadCount), action: nil, keyEquivalent: "")
                item.image = menuImage(for: feed)
                let submenu = NSMenu()

                addFeedActions(to: submenu, feed: feed, stories: stories)
                submenu.addItem(.separator())
                if stories.isEmpty {
                    let empty = NSMenuItem(title: "No stories loaded", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                } else {
                    for story in stories {
                        submenu.addItem(storyMenuItem(story))
                    }
                }

                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }

    private var allLoadedStories: [FeedStory] {
        storiesByFeed.values.flatMap { $0 }
    }

    private var totalUnreadCount: Int {
        allLoadedStories.filter { !store.isStoryRead($0) }.count
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let unreadCount = totalUnreadCount
        let countTitle = store.showUnreadCountInMenuBar && unreadCount > 0 ? "\(unreadCount)" : ""

        if store.showMenuBarIcon {
            button.image = statusIcon(unreadCount: unreadCount)
            button.imagePosition = countTitle.isEmpty ? .imageOnly : .imageLeft
            button.title = countTitle
        } else {
            button.image = nil
            button.title = countTitle.isEmpty ? "RSS" : "RSS \(countTitle)"
        }
    }

    private func statusIcon(unreadCount: Int) -> NSImage? {
        let hasUnread = unreadCount > 0
        let name = hasUnread || !store.highlightUnreadInStatusItem ? "MenuIconUnread" : "MenuIconRead"
        let image = NSImage(named: name)
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func addGlobalMenuItems() {
        if store.showGlobalUpdateAll {
            let refreshAll = NSMenuItem(title: "Update all feeds", action: #selector(refreshAllFromMenu), keyEquivalent: "r")
            refreshAll.target = self
            refreshAll.isEnabled = !updatesPaused
            menu.addItem(refreshAll)
        }

        if store.showGlobalMarkAllRead {
            let markAllRead = NSMenuItem(title: "Mark all read", action: #selector(markAllReadFromMenu), keyEquivalent: "")
            markAllRead.target = self
            markAllRead.isEnabled = allLoadedStories.contains { !store.isStoryRead($0) }
            menu.addItem(markAllRead)
        }

        if store.showGlobalMarkAllUnread {
            let markAllUnread = NSMenuItem(title: "Mark all unread", action: #selector(markAllUnreadFromMenu), keyEquivalent: "")
            markAllUnread.target = self
            markAllUnread.isEnabled = allLoadedStories.contains { store.isStoryRead($0) }
            menu.addItem(markAllUnread)
        }

        if store.showGlobalShowAllUnread {
            let showAllUnread = NSMenuItem(title: "Show all unread", action: #selector(showAllUnreadGloballyFromMenu), keyEquivalent: "")
            showAllUnread.target = self
            showAllUnread.isEnabled = totalUnreadCount > 0
            menu.addItem(showAllUnread)
        }
    }

    private func generalMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "General", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let about = NSMenuItem(title: "About MicroRSS", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        submenu.addItem(about)

        let preferences = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        submenu.addItem(preferences)

        submenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        submenu.addItem(quit)

        item.submenu = submenu
        return item
    }

    private func addFeedActions(to submenu: NSMenu, feed: Feed, stories: [FeedStory]) {
        let unreadStories = store.unreadStories(in: stories)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshFeedFromMenu(_:)), keyEquivalent: "")
        refresh.target = self
        refresh.representedObject = feed.id
        refresh.isEnabled = !updatesPaused
        submenu.addItem(refresh)

        let markRead = NSMenuItem(title: "Mark all read", action: #selector(markFeedReadFromMenu(_:)), keyEquivalent: "")
        markRead.target = self
        markRead.representedObject = feed.id
        markRead.isEnabled = !unreadStories.isEmpty
        submenu.addItem(markRead)

        let markUnread = NSMenuItem(title: "Mark all unread", action: #selector(markFeedUnreadFromMenu(_:)), keyEquivalent: "")
        markUnread.target = self
        markUnread.representedObject = feed.id
        markUnread.isEnabled = stories.contains { store.isStoryRead($0) }
        submenu.addItem(markUnread)

        let showUnread = NSMenuItem(title: "Show all unread", action: #selector(showAllUnreadFromMenu(_:)), keyEquivalent: "")
        showUnread.target = self
        showUnread.representedObject = feed.id
        showUnread.isEnabled = !unreadStories.isEmpty
        submenu.addItem(showUnread)
    }

    private func feedMenuTitle(feed: Feed, unreadCount: Int) -> String {
        store.showUnreadCountInFeeds && unreadCount > 0 ? "\(feed.displayName) (\(unreadCount))" : feed.displayName
    }

    private func menuImage(for feed: Feed) -> NSImage? {
        guard let image = iconCache.image(for: feed) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func storyMenuItem(_ story: FeedStory) -> NSMenuItem {
        let item = NSMenuItem(title: story.title, action: #selector(openStory(_:)), keyEquivalent: "")
        item.target = self
        let submenu = NSMenu()
        let feed = store.feeds.first { $0.id == story.sourceFeedID }
        if let feed {
            item.representedObject = FeedStoryContext(story: story, feed: feed)
        } else {
            item.representedObject = story
        }
        item.state = store.isStoryRead(story) ? .off : .on

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

        item.submenu = submenu
        return item
    }

    private func rescheduleRefresh() {
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        guard !updatesPaused else { return }
        for feed in store.feeds {
            guard refreshMinutes(for: feed.id) > 0 else { continue }
            refreshTasks[feed.id] = Task { [weak self] in
                await self?.refreshLoop(feedID: feed.id)
            }
        }
    }

    private func refreshLoop(feedID: UUID) async {
        while !Task.isCancelled {
            await refreshFeed(id: feedID)
            let minutes = refreshMinutes(for: feedID)
            guard minutes > 0 else { return }
            let seconds = minutes * 60
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        }
    }

    private func refreshMinutes(for feedID: UUID) -> Int {
        store.feeds.first(where: { $0.id == feedID })?.refreshMinutes ?? store.globalRefreshMinutes
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
        guard !updatesPaused else { return }
        for feed in store.feeds {
            Task { await refreshFeed(id: feed.id) }
        }
    }

    @objc private func refreshFeedFromMenu(_ sender: NSMenuItem) {
        guard !updatesPaused else { return }
        guard let id = sender.representedObject as? UUID else { return }
        Task { await refreshFeed(id: id) }
    }

    @objc private func toggleUpdatesPaused() {
        updatesPaused.toggle()
        rescheduleRefresh()
        rebuildMenu()
    }

    @objc private func markAllReadFromMenu() {
        store.markStories(allLoadedStories, read: true)
    }

    @objc private func markAllUnreadFromMenu() {
        store.markStories(allLoadedStories, read: false)
    }

    @objc private func showAllUnreadGloballyFromMenu() {
        openStories(store.unreadStories(in: allLoadedStories))
    }

    @objc private func markFeedReadFromMenu(_ sender: NSMenuItem) {
        guard let stories = storiesForMenuItem(sender) else { return }
        store.markStories(stories, read: true)
    }

    @objc private func markFeedUnreadFromMenu(_ sender: NSMenuItem) {
        guard let stories = storiesForMenuItem(sender) else { return }
        store.markStories(stories, read: false)
    }

    @objc private func showAllUnreadFromMenu(_ sender: NSMenuItem) {
        guard let stories = storiesForMenuItem(sender) else { return }
        openStories(store.unreadStories(in: stories))
    }

    private func storiesForMenuItem(_ sender: NSMenuItem) -> [FeedStory]? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return storiesByFeed[id] ?? []
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
            store.markStory(context.story, read: true)
            controller = PreviewWindowController(story: context.story, feed: context.feed)
        } else if let story = sender.representedObject as? FeedStory {
            store.markStory(story, read: true)
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
            store.markStory(context.story, read: true)
            NSWorkspace.shared.open(url)
        } else if let story = sender.representedObject as? FeedStory, let url = story.link {
            store.markStory(story, read: true)
            NSWorkspace.shared.open(url)
        }
    }

    private func openStories(_ stories: [FeedStory]) {
        for story in stories {
            guard let feed = store.feeds.first(where: { $0.id == story.sourceFeedID }),
                  let url = Self.storyURL(for: story, feed: feed) ?? story.link else { continue }
            store.markStory(story, read: true)
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
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
