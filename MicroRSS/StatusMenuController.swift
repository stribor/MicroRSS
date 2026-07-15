import AppKit
import UserNotifications
import WebKit

@MainActor
final class StatusMenuController: NSObject {
    private let store: FeedStore
    private let service: RSSService
    private let iconCache = FeedIconCache()
    private let notificationController = FeedNotificationController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var storiesByFeed: [UUID: [FeedStory]] = [:]
    private var knownStoryIDsByFeed: [UUID: Set<String>] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var preferencesWindowController: PreferencesWindowController?
    private var previewWindows: [PreviewWindowRecord] = []
    private var storeObserverID: UUID?
    private var updatesPaused = false

    init(store: FeedStore, service: RSSService) {
        self.store = store
        self.service = service
        super.init()
        notificationController.articleHandler = { [weak self] article in
            self?.openNotificationArticle(article)
        }
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

        if let allFeeds = allFeedsMenuItem() {
            menu.addItem(allFeeds)
        }
        menu.addItem(.separator())

        if store.items.isEmpty {
            let empty = NSMenuItem(title: "No feeds configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for item in store.items {
                guard case .feed(let feed) = item else {
                    menu.addItem(.separator())
                    continue
                }

                let stories = storiesByFeed[feed.id] ?? []
                let unreadCount = store.unreadStories(in: stories).count
                let item = NSMenuItem(title: feedMenuTitle(feed: feed, unreadCount: unreadCount), action: nil, keyEquivalent: "")
                item.image = menuImage(for: feed)
                item.representedObject = feed.id
                let submenu = NSMenu()

                addFeedActions(to: submenu, feed: feed, stories: stories)
                submenu.addItem(.separator())
                if stories.isEmpty {
                    let empty = NSMenuItem(title: "No stories loaded", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                } else {
                    for story in stories {
                        storyMenuItems(story).forEach(submenu.addItem)
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
            ?? NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "MicroRSS")
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func allFeedsMenuItem() -> NSMenuItem? {
        let item = NSMenuItem(title: "All Feeds", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if store.showGlobalUpdateAll {
            let refreshAll = NSMenuItem(title: "Update", action: #selector(refreshAllFromMenu), keyEquivalent: "r")
            refreshAll.target = self
            refreshAll.isEnabled = !updatesPaused
            submenu.addItem(refreshAll)
        }

        if store.showGlobalMarkAllRead {
            let markAllRead = NSMenuItem(title: "Mark all read", action: #selector(markAllReadFromMenu), keyEquivalent: "")
            markAllRead.target = self
            markAllRead.isEnabled = allLoadedStories.contains { !store.isStoryRead($0) }
            submenu.addItem(markAllRead)
        }

        if store.showGlobalMarkAllUnread {
            let markAllUnread = NSMenuItem(title: "Mark all unread", action: #selector(markAllUnreadFromMenu), keyEquivalent: "")
            markAllUnread.target = self
            markAllUnread.isEnabled = allLoadedStories.contains { store.isStoryRead($0) }
            submenu.addItem(markAllUnread)
        }

        if store.showGlobalShowAllUnread {
            let showAllUnread = NSMenuItem(title: "Show all unread", action: #selector(showAllUnreadGloballyFromMenu), keyEquivalent: "")
            showAllUnread.target = self
            showAllUnread.isEnabled = totalUnreadCount > 0
            submenu.addItem(showAllUnread)
        }

        guard !submenu.items.isEmpty else { return nil }
        item.submenu = submenu
        return item
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

    private func storyMenuItems(_ story: FeedStory) -> [NSMenuItem] {
        let fullTitle = singleLineStoryTitle(story.title)
        let shortenedTitle = limitedStoryMenuTitle(fullTitle)
        let normalItem = storyMenuItem(story, title: shortenedTitle)
        guard shortenedTitle != fullTitle else { return [normalItem] }

        let alternateItem = storyMenuItem(story, title: fullTitle)
        alternateItem.isAlternate = true
        alternateItem.keyEquivalentModifierMask = [.option]
        return [normalItem, alternateItem]
    }

    private func storyMenuItem(_ story: FeedStory, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openStory(_:)), keyEquivalent: "")
        item.toolTip = story.title
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
        preview.view = StoryPreviewMenuView(
            story: story,
            feed: feed,
            size: NSSize(width: store.previewMenuWidth, height: store.previewMenuHeight),
            markReadDelaySeconds: store.previewMarkReadDelaySeconds
        ) { [weak self, weak item] story in
            self?.markStoryReadFromPreview(story, menuItem: item)
        }
        submenu.addItem(preview)

        let previewWindow = NSMenuItem(title: "Open Preview Window", action: #selector(openPreview(_:)), keyEquivalent: "")
        previewWindow.target = self
        if let feed {
            previewWindow.representedObject = PreviewWindowContext(story: story, feed: feed)
        } else {
            previewWindow.representedObject = PreviewWindowContext(story: story, feed: nil)
        }
        previewWindow.state = isPreviewWindowOpen(for: story) ? .on : .off
        previewWindow.isEnabled = story.link != nil
        submenu.addItem(previewWindow)

        item.submenu = submenu
        return item
    }

    private func singleLineStoryTitle(_ title: String) -> String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func limitedStoryMenuTitle(_ title: String) -> String {
        let limit = store.storyMenuTitleLength
        guard limit > 0, title.count > limit else { return title }
        guard limit > 1 else { return "…" }
        return String(title.prefix(limit - 1)) + "…"
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
            let newStories = newStories(in: stories, feedID: id)
            storiesByFeed[id] = stories
            updateFeedMetadata(feed: feed, metadata: metadata)
            if store.notificationsEnabled, !newStories.isEmpty {
                let updatedFeed = store.feeds.first(where: { $0.id == id }) ?? feed
                notificationController.showNotification(
                    for: updatedFeed,
                    newStories: newStories,
                    feedDescription: metadata.description
                )
            }
            rebuildMenu()
        } catch {
            rebuildMenu()
        }
    }

    private func newStories(in stories: [FeedStory], feedID: UUID) -> [FeedStory] {
        let knownIDs = knownStoryIDsByFeed[feedID]
        let fetchedIDs = Set(stories.map(\.id))
        knownStoryIDsByFeed[feedID] = (knownIDs ?? []).union(fetchedIDs)

        guard let knownIDs else { return [] }
        return stories.filter { !knownIDs.contains($0.id) }
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

    private func markStoryReadFromPreview(_ story: FeedStory, menuItem: NSMenuItem?) {
        guard store.markStory(story, read: true, notifyObservers: false) else { return }
        menuItem?.state = .off
        updateVisibleMenuItems()
        updateStatusItem()
    }

    private func updateVisibleMenuItems() {
        updateItems(in: menu)
    }

    private func updateItems(in menu: NSMenu) {
        for item in menu.items {
            if let context = item.representedObject as? FeedStoryContext {
                item.state = store.isStoryRead(context.story) ? .off : .on
            } else if let context = item.representedObject as? PreviewWindowContext {
                item.state = isPreviewWindowOpen(for: context.story) ? .on : .off
            } else if let story = item.representedObject as? FeedStory {
                item.state = store.isStoryRead(story) ? .off : .on
            } else if let id = item.representedObject as? UUID, let stories = storiesByFeed[id] {
                updateFeedItem(item, feedID: id, stories: stories)
            } else {
                updateGlobalActionItem(item)
            }

            if let submenu = item.submenu {
                updateItems(in: submenu)
            }
        }
    }

    private func updateFeedItem(_ item: NSMenuItem, feedID: UUID, stories: [FeedStory]) {
        switch item.action {
        case #selector(markFeedReadFromMenu(_:)), #selector(showAllUnreadFromMenu(_:)):
            item.isEnabled = stories.contains { !store.isStoryRead($0) }
        case #selector(markFeedUnreadFromMenu(_:)):
            item.isEnabled = stories.contains { store.isStoryRead($0) }
        default:
            if item.submenu != nil, let feed = store.feeds.first(where: { $0.id == feedID }) {
                let unreadCount = stories.filter { !store.isStoryRead($0) }.count
                item.title = feedMenuTitle(feed: feed, unreadCount: unreadCount)
            }
        }
    }

    private func updateGlobalActionItem(_ item: NSMenuItem) {
        switch item.action {
        case #selector(markAllReadFromMenu), #selector(showAllUnreadGloballyFromMenu):
            item.isEnabled = allLoadedStories.contains { !store.isStoryRead($0) }
        case #selector(markAllUnreadFromMenu):
            item.isEnabled = allLoadedStories.contains { store.isStoryRead($0) }
        default:
            break
        }
    }

    func showSettings() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(store: store)
        }
        if preferencesWindowController?.window?.isVisible == false {
            preferencesWindowController?.window?.center()
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func openPreview(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? PreviewWindowContext else { return }
        let key = previewWindowKey(for: context.story)
        if let existing = previewWindows.first(where: { $0.key == key })?.controller {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        store.markStory(context.story, read: true)
        let controller = PreviewWindowController(story: context.story, feed: context.feed)
        previewWindows.append(PreviewWindowRecord(key: key, controller: controller))
        controller.window?.delegate = self
        controller.showWindow(nil)
        updateVisibleMenuItems()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openStory(_ sender: NSMenuItem) {
        if let context = sender.representedObject as? FeedStoryContext,
           let url = context.story.link {
            store.markStory(context.story, read: true)
            NSWorkspace.shared.open(url)
        } else if let story = sender.representedObject as? FeedStory, let url = story.link {
            store.markStory(story, read: true)
            NSWorkspace.shared.open(url)
        }
    }

    private func openNotificationArticle(_ article: NotificationArticle) {
        if let story = storiesByFeed[article.feedID]?.first(where: { $0.id == article.storyID }) {
            store.markStory(story, read: true)
        }
        NSWorkspace.shared.open(article.url)
    }

    private func openStories(_ stories: [FeedStory]) {
        for story in stories {
            guard let url = story.link else { continue }
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

    static func storyRequest(for story: FeedStory, feed: Feed?) -> URLRequest? {
        guard let url = story.link else { return nil }
        var request = URLRequest(url: url)
        if let feed {
            request.setValue(feed.url.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private func isPreviewWindowOpen(for story: FeedStory) -> Bool {
        let key = previewWindowKey(for: story)
        return previewWindows.contains { $0.key == key }
    }

    private func previewWindowKey(for story: FeedStory) -> String {
        "\(story.sourceFeedID.uuidString)|\(story.id)"
    }
}

extension StatusMenuController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        previewWindows.removeAll { $0.controller.window === notification.object as? NSWindow }
        updateVisibleMenuItems()
    }
}

private struct PreviewWindowContext {
    var story: FeedStory
    var feed: Feed?
}

private struct PreviewWindowRecord {
    var key: String
    var controller: NSWindowController
}

private struct NotificationArticle: Sendable {
    var feedID: UUID
    var storyID: String
    var url: URL
}

@MainActor
private final class FeedNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var didRequestAuthorization = false
    var articleHandler: ((NotificationArticle) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func showNotification(for feed: Feed, newStories: [FeedStory], feedDescription: String?) {
        Task {
            guard await notificationsAllowed() else { return }

            let content = UNMutableNotificationContent()
            content.title = feed.displayName
            content.subtitle = Self.subtitle(for: newStories)
            content.body = Self.body(feedDescription: feedDescription, newStories: newStories)
            content.sound = .default
            if let story = newStories.first, let url = story.link {
                content.userInfo = [
                    "feedID": story.sourceFeedID.uuidString,
                    "storyID": story.id,
                    "articleURL": url.absoluteString
                ]
            }

            let request = UNNotificationRequest(
                identifier: "\(feed.id.uuidString)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let article = Self.article(from: response.notification.request.content.userInfo) else {
            return
        }
        await MainActor.run { [weak self] in
            self?.articleHandler?(article)
        }
    }

    private func notificationsAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard !didRequestAuthorization else { return false }
            didRequestAuthorization = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func subtitle(for stories: [FeedStory]) -> String {
        if stories.count == 1 {
            return stories[0].title
        }
        return "\(stories.count) new stories"
    }

    private static func body(feedDescription: String?, newStories: [FeedStory]) -> String {
        if let description = feedDescription?.notificationPlainText, !description.isEmpty {
            return description
        }
        return newStories.prefix(3).map(\.title).joined(separator: "\n")
    }

    nonisolated private static func article(from userInfo: [AnyHashable: Any]) -> NotificationArticle? {
        guard let feedIDString = userInfo["feedID"] as? String,
              let feedID = UUID(uuidString: feedIDString),
              let storyID = userInfo["storyID"] as? String,
              let urlString = userInfo["articleURL"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        return NotificationArticle(feedID: feedID, storyID: storyID, url: url)
    }
}

private final class StoryPreviewMenuView: NSView {
    private let story: FeedStory
    private let feed: Feed?
    private let previewSize: NSSize
    private let markReadDelaySeconds: Int
    private let markRead: (FeedStory) -> Void
    private var webView: WKWebView?
    private var didStartLoading = false
    private var markReadTask: Task<Void, Never>?
    private var didMarkRead = false

    init(story: FeedStory, feed: Feed?, size: NSSize, markReadDelaySeconds: Int, markRead: @escaping (FeedStory) -> Void) {
        self.story = story
        self.feed = feed
        previewSize = NSSize(width: max(240, size.width), height: max(240, size.height))
        self.markReadDelaySeconds = max(0, markReadDelaySeconds)
        self.markRead = markRead
        super.init(frame: NSRect(origin: .zero, size: previewSize))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        previewSize
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
        if window == nil {
            cancelMarkReadTask()
            return
        }

        scheduleMarkRead()
        guard !didStartLoading else { return }
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

    private func scheduleMarkRead() {
        guard markReadDelaySeconds > 0, !didMarkRead, markReadTask == nil else { return }
        let delay = markReadDelayNanoseconds()
        markReadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.window != nil, !self.didMarkRead else { return }
                self.didMarkRead = true
                self.markRead(self.story)
                self.markReadTask = nil
            }
        }
    }

    private func markReadDelayNanoseconds() -> UInt64 {
        let (delay, overflow) = UInt64(markReadDelaySeconds).multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? UInt64.max : delay
    }

    private func cancelMarkReadTask() {
        markReadTask?.cancel()
        markReadTask = nil
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

private extension String {
    var notificationPlainText: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var escapedHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
