import Foundation

@MainActor
final class FeedStore {
    private struct StoredState: Codable {
        var globalRefreshMinutes: Int
        var feeds: [Feed]
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
    private(set) var feeds: [Feed]
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
            feeds = decoded.feeds
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
            feeds = []
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
        feeds.append(Feed(id: UUID(), name: name, url: url, refreshMinutes: refreshMinutes, iconURL: nil))
        save()
    }

    func updateFeed(_ feed: Feed) {
        guard let index = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[index] = feed
        save()
    }

    func update(globalRefreshMinutes: Int, feed: Feed?) {
        self.globalRefreshMinutes = max(0, globalRefreshMinutes)
        if let feed, let index = feeds.firstIndex(where: { $0.id == feed.id }) {
            feeds[index] = feed
        }
        save()
    }

    func removeFeed(id: UUID) {
        feeds.removeAll { $0.id == id }
        save()
    }

    func moveFeed(from source: Int, to destination: Int) {
        guard feeds.indices.contains(source), feeds.indices.contains(destination), source != destination else { return }
        let feed = feeds.remove(at: source)
        feeds.insert(feed, at: destination)
        save()
    }

    func isStoryRead(_ story: FeedStory) -> Bool {
        readStoryIDs.contains(readID(for: story))
    }

    func unreadStories(in stories: [FeedStory]) -> [FeedStory] {
        stories.filter { !isStoryRead($0) }
    }

    func markStory(_ story: FeedStory, read: Bool) {
        let id = readID(for: story)
        if read {
            readStoryIDs.insert(id)
        } else {
            readStoryIDs.remove(id)
        }
        save()
    }

    func markStories(_ stories: [FeedStory], read: Bool) {
        for story in stories {
            let id = readID(for: story)
            if read {
                readStoryIDs.insert(id)
            } else {
                readStoryIDs.remove(id)
            }
        }
        save()
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

    private func save() {
        let state = StoredState(
            globalRefreshMinutes: globalRefreshMinutes,
            feeds: feeds,
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
        observers.values.forEach { $0() }
    }

    private func readID(for story: FeedStory) -> String {
        "\(story.sourceFeedID.uuidString)|\(story.id)"
    }
}
