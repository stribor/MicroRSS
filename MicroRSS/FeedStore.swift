import Foundation

@MainActor
final class FeedStore {
    private struct StoredState: Codable {
        var globalRefreshMinutes: Int
        var feeds: [Feed]?
        var items: [FeedListItem]?
        var launchAtLogin: Bool?
        var notificationsEnabled: Bool?
        var highlightUnreadInStatusItem: Bool?
        var readStoryIDs: Set<String>?
        var showMenuBarIcon: Bool?
        var showUnreadCountInMenuBar: Bool?
        var showUnreadCountInFeeds: Bool?
        var showGlobalUpdateAll: Bool?
        var showGlobalMarkAllRead: Bool?
        var showGlobalMarkAllUnread: Bool?
        var showGlobalShowAllUnread: Bool?
    }

    private let defaults: UserDefaults
    private let key = "MicroRSS.FeedStore.v1"

    private(set) var globalRefreshMinutes: Int
    private(set) var launchAtLogin: Bool
    private(set) var notificationsEnabled: Bool
    private(set) var highlightUnreadInStatusItem: Bool
    private(set) var showMenuBarIcon: Bool
    private(set) var showUnreadCountInMenuBar: Bool
    private(set) var showUnreadCountInFeeds: Bool
    private(set) var showGlobalUpdateAll: Bool
    private(set) var showGlobalMarkAllRead: Bool
    private(set) var showGlobalMarkAllUnread: Bool
    private(set) var showGlobalShowAllUnread: Bool
    private(set) var items: [FeedListItem]
    var feeds: [Feed] {
        items.compactMap(\.feed)
    }
    private var readStoryIDs: Set<String>

    private var observers: [UUID: () -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            globalRefreshMinutes = decoded.globalRefreshMinutes
            launchAtLogin = decoded.launchAtLogin ?? false
            notificationsEnabled = decoded.notificationsEnabled ?? true
            highlightUnreadInStatusItem = decoded.highlightUnreadInStatusItem ?? true
            items = decoded.items ?? (decoded.feeds ?? []).map(FeedListItem.init(feed:))
            readStoryIDs = decoded.readStoryIDs ?? []
            showMenuBarIcon = decoded.showMenuBarIcon ?? true
            showUnreadCountInMenuBar = decoded.showUnreadCountInMenuBar ?? true
            showUnreadCountInFeeds = decoded.showUnreadCountInFeeds ?? true
            showGlobalUpdateAll = decoded.showGlobalUpdateAll ?? true
            showGlobalMarkAllRead = decoded.showGlobalMarkAllRead ?? true
            showGlobalMarkAllUnread = decoded.showGlobalMarkAllUnread ?? true
            showGlobalShowAllUnread = decoded.showGlobalShowAllUnread ?? true
        } else {
            globalRefreshMinutes = 30
            launchAtLogin = false
            notificationsEnabled = true
            highlightUnreadInStatusItem = true
            items = []
            readStoryIDs = []
            showMenuBarIcon = true
            showUnreadCountInMenuBar = true
            showUnreadCountInFeeds = true
            showGlobalUpdateAll = true
            showGlobalMarkAllRead = true
            showGlobalMarkAllUnread = true
            showGlobalShowAllUnread = true
        }
    }

    func updateGeneral(
        globalRefreshMinutes: Int,
        launchAtLogin: Bool,
        notificationsEnabled: Bool,
        highlightUnreadInStatusItem: Bool,
        showMenuBarIcon: Bool,
        showUnreadCountInMenuBar: Bool,
        showUnreadCountInFeeds: Bool,
        showGlobalUpdateAll: Bool,
        showGlobalMarkAllRead: Bool,
        showGlobalMarkAllUnread: Bool,
        showGlobalShowAllUnread: Bool
    ) {
        self.globalRefreshMinutes = max(0, globalRefreshMinutes)
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.highlightUnreadInStatusItem = highlightUnreadInStatusItem
        self.showMenuBarIcon = showMenuBarIcon
        self.showUnreadCountInMenuBar = showUnreadCountInMenuBar
        self.showUnreadCountInFeeds = showUnreadCountInFeeds
        self.showGlobalUpdateAll = showGlobalUpdateAll
        self.showGlobalMarkAllRead = showGlobalMarkAllRead
        self.showGlobalMarkAllUnread = showGlobalMarkAllUnread
        self.showGlobalShowAllUnread = showGlobalShowAllUnread
        save()
    }

    func updateGlobalRefresh(minutes: Int) {
        globalRefreshMinutes = max(0, minutes)
        save()
    }

    func addFeed(url: URL, name: String = "", refreshMinutes: Int? = nil) {
        items.append(.feed(Feed(id: UUID(), name: name, url: url, refreshMinutes: refreshMinutes, iconURL: nil)))
        save()
    }

    func addSeparator(title: String = "") {
        items.append(.separator(FeedSeparator(id: UUID(), title: title)))
        save()
    }

    func updateFeed(_ feed: Feed) {
        guard let index = items.firstIndex(where: { $0.id == feed.id }) else { return }
        items[index] = .feed(feed)
        save()
    }

    func updateSeparator(_ separator: FeedSeparator) {
        guard let index = items.firstIndex(where: { $0.id == separator.id }) else { return }
        items[index] = .separator(separator)
        save()
    }

    func update(globalRefreshMinutes: Int, feed: Feed?) {
        self.globalRefreshMinutes = max(0, globalRefreshMinutes)
        if let feed, let index = items.firstIndex(where: { $0.id == feed.id }) {
            items[index] = .feed(feed)
        }
        save()
    }

    func removeFeed(id: UUID) {
        removeItem(id: id)
    }

    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func moveItem(from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let item = items.remove(at: source)
        items.insert(item, at: destination)
        save()
    }

    func moveFeed(from source: Int, to destination: Int) {
        moveItem(from: source, to: destination)
    }

    func isStoryRead(_ story: FeedStory) -> Bool {
        readStoryIDs.contains(readID(for: story))
    }

    func unreadStories(in stories: [FeedStory]) -> [FeedStory] {
        stories.filter { !isStoryRead($0) }
    }

    func markStory(_ story: FeedStory, read: Bool, notifyObservers: Bool = true) {
        let id = readID(for: story)
        let changed: Bool
        if read {
            changed = readStoryIDs.insert(id).inserted
        } else {
            changed = readStoryIDs.remove(id) != nil
        }
        guard changed else { return }
        save(notifyObservers: notifyObservers)
    }

    func markStories(_ stories: [FeedStory], read: Bool, notifyObservers: Bool = true) {
        var changed = false
        for story in stories {
            let id = readID(for: story)
            if read {
                changed = readStoryIDs.insert(id).inserted || changed
            } else {
                changed = (readStoryIDs.remove(id) != nil) || changed
            }
        }
        guard changed else { return }
        save(notifyObservers: notifyObservers)
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(id: UUID) {
        observers[id] = nil
    }

    private func save(notifyObservers: Bool = true) {
        let state = StoredState(
            globalRefreshMinutes: globalRefreshMinutes,
            feeds: feeds,
            items: items,
            launchAtLogin: launchAtLogin,
            notificationsEnabled: notificationsEnabled,
            highlightUnreadInStatusItem: highlightUnreadInStatusItem,
            readStoryIDs: readStoryIDs,
            showMenuBarIcon: showMenuBarIcon,
            showUnreadCountInMenuBar: showUnreadCountInMenuBar,
            showUnreadCountInFeeds: showUnreadCountInFeeds,
            showGlobalUpdateAll: showGlobalUpdateAll,
            showGlobalMarkAllRead: showGlobalMarkAllRead,
            showGlobalMarkAllUnread: showGlobalMarkAllUnread,
            showGlobalShowAllUnread: showGlobalShowAllUnread
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
        if notifyObservers {
            observers.values.forEach { $0() }
        }
    }

    private func readID(for story: FeedStory) -> String {
        "\(story.sourceFeedID.uuidString)|\(story.id)"
    }
}
