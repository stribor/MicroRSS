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
        var previewMarkReadDelaySeconds: Int?
        var previewMenuWidth: Int?
        var previewMenuHeight: Int?
        var storyMenuTitleLength: Int?
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

    let isFreshInstall: Bool
    private(set) var globalRefreshMinutes: Int
    private(set) var launchAtLogin: Bool
    private(set) var notificationsEnabled: Bool
    private(set) var highlightUnreadInStatusItem: Bool
    private(set) var previewMarkReadDelaySeconds: Int
    private(set) var previewMenuWidth: Int
    private(set) var previewMenuHeight: Int
    private(set) var storyMenuTitleLength: Int
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
        isFreshInstall = defaults.data(forKey: key) == nil
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            globalRefreshMinutes = decoded.globalRefreshMinutes
            launchAtLogin = decoded.launchAtLogin ?? false
            notificationsEnabled = decoded.notificationsEnabled ?? true
            highlightUnreadInStatusItem = decoded.highlightUnreadInStatusItem ?? true
            previewMarkReadDelaySeconds = decoded.previewMarkReadDelaySeconds ?? 3
            previewMenuWidth = Self.validPreviewMenuDimension(decoded.previewMenuWidth, defaultValue: 800)
            previewMenuHeight = Self.validPreviewMenuDimension(decoded.previewMenuHeight, defaultValue: 600)
            storyMenuTitleLength = max(0, decoded.storyMenuTitleLength ?? 0)
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
            previewMarkReadDelaySeconds = 3
            previewMenuWidth = 800
            previewMenuHeight = 600
            storyMenuTitleLength = 0
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
        previewMarkReadDelaySeconds: Int,
        previewMenuWidth: Int,
        previewMenuHeight: Int,
        storyMenuTitleLength: Int,
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
        self.previewMarkReadDelaySeconds = max(0, previewMarkReadDelaySeconds)
        self.previewMenuWidth = Self.validPreviewMenuDimension(previewMenuWidth, defaultValue: self.previewMenuWidth)
        self.previewMenuHeight = Self.validPreviewMenuDimension(previewMenuHeight, defaultValue: self.previewMenuHeight)
        self.storyMenuTitleLength = max(0, storyMenuTitleLength)
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

    @discardableResult
    func importFeeds(_ importedFeeds: [Feed]) -> FeedImportResult {
        var result = FeedImportResult(added: 0, updated: 0)
        var indexesByURL: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            guard let feed = item.feed else { continue }
            let key = FeedTransfer.canonicalURL(feed.url)
            if indexesByURL[key] == nil {
                indexesByURL[key] = index
            }
        }

        for importedFeed in importedFeeds {
            let key = FeedTransfer.canonicalURL(importedFeed.url)
            if let index = indexesByURL[key], case .feed(var existingFeed) = items[index] {
                guard !importedFeed.name.isEmpty, existingFeed.name != importedFeed.name else { continue }
                existingFeed.name = importedFeed.name
                items[index] = .feed(existingFeed)
                result.updated += 1
            } else {
                var newFeed = importedFeed
                newFeed.id = UUID()
                items.append(.feed(newFeed))
                indexesByURL[key] = items.count - 1
                result.added += 1
            }
        }

        if result.added > 0 || result.updated > 0 {
            save()
        }
        return result
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

    func removeItems(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func moveItem(from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let item = items.remove(at: source)
        items.insert(item, at: destination)
        save()
    }

    @discardableResult
    func moveItems(at sourceIndexes: IndexSet, to destination: Int) -> Int? {
        let sources = sourceIndexes.filter { items.indices.contains($0) }
        guard !sources.isEmpty else { return nil }

        let movingItems = sources.map { items[$0] }
        var reorderedItems = items
        for source in sources.reversed() {
            reorderedItems.remove(at: source)
        }

        let removedBeforeDestination = sources.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), reorderedItems.count)
        reorderedItems.insert(contentsOf: movingItems, at: insertionIndex)
        guard reorderedItems != items else { return nil }

        items = reorderedItems
        save()
        return insertionIndex
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

    @discardableResult
    func markStory(_ story: FeedStory, read: Bool, notifyObservers: Bool = true) -> Bool {
        let id = readID(for: story)
        let changed: Bool
        if read {
            changed = readStoryIDs.insert(id).inserted
        } else {
            changed = readStoryIDs.remove(id) != nil
        }
        guard changed else { return false }
        save(notifyObservers: notifyObservers)
        return true
    }

    @discardableResult
    func markStories(_ stories: [FeedStory], read: Bool, notifyObservers: Bool = true) -> Bool {
        var changed = false
        for story in stories {
            let id = readID(for: story)
            if read {
                changed = readStoryIDs.insert(id).inserted || changed
            } else {
                changed = (readStoryIDs.remove(id) != nil) || changed
            }
        }
        guard changed else { return false }
        save(notifyObservers: notifyObservers)
        return true
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
            previewMarkReadDelaySeconds: previewMarkReadDelaySeconds,
            previewMenuWidth: previewMenuWidth,
            previewMenuHeight: previewMenuHeight,
            storyMenuTitleLength: storyMenuTitleLength,
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

    private static func validPreviewMenuDimension(_ value: Int?, defaultValue: Int) -> Int {
        guard let value else { return defaultValue }
        return max(240, value)
    }
}
