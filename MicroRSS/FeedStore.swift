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
    }

    private let defaults: UserDefaults
    private let key = "MicroRSS.FeedStore.v1"

    private(set) var globalRefreshMinutes: Int
    private(set) var launchAtLogin: Bool
    private(set) var notificationsEnabled: Bool
    private(set) var highlightUnreadInStatusItem: Bool
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
        } else {
            globalRefreshMinutes = 30
            launchAtLogin = false
            notificationsEnabled = true
            highlightUnreadInStatusItem = true
            feeds = []
            readStoryIDs = []
        }
    }

    func updateGeneral(
        globalRefreshMinutes: Int,
        launchAtLogin: Bool,
        notificationsEnabled: Bool,
        highlightUnreadInStatusItem: Bool
    ) {
        self.globalRefreshMinutes = max(1, globalRefreshMinutes)
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.highlightUnreadInStatusItem = highlightUnreadInStatusItem
        save()
    }

    func updateGlobalRefresh(minutes: Int) {
        globalRefreshMinutes = max(1, minutes)
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
        self.globalRefreshMinutes = max(1, globalRefreshMinutes)
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
            readStoryIDs: readStoryIDs
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
