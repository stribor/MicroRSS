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

        let preview = NSMenuItem(title: "Preview", action: #selector(openPreview(_:)), keyEquivalent: "")
        preview.target = self
        preview.representedObject = story
        submenu.addItem(preview)

        let open = NSMenuItem(title: "Open in Browser", action: #selector(openStory(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = story
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
        guard let story = sender.representedObject as? FeedStory else { return }
        let controller = PreviewWindowController(story: story)
        previewWindows.append(controller)
        controller.window?.delegate = self
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openStory(_ sender: NSMenuItem) {
        guard let story = sender.representedObject as? FeedStory, let url = story.link else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusMenuController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        previewWindows.removeAll { $0.window === notification.object as? NSWindow }
    }
}
