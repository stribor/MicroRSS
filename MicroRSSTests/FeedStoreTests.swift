import XCTest
@testable import MicroRSS

@MainActor
final class FeedStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "MicroRSSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    func testFreshStoreUsesExpectedDefaultsAndPersistsClampedSettings() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FeedStore(defaults: defaults)

        XCTAssertTrue(store.isFreshInstall)
        XCTAssertEqual(store.globalRefreshMinutes, 30)
        XCTAssertEqual(store.previewMenuWidth, 800)
        XCTAssertTrue(store.hideDockIcon)
        XCTAssertEqual(store.supplementaryAdBlockRules, "")

        store.updateGeneral(
            globalRefreshMinutes: -10,
            launchAtLogin: true,
            hideDockIcon: false,
            notificationsEnabled: false,
            highlightUnreadInStatusItem: false,
            previewMarkReadDelaySeconds: -2,
            previewMenuWidth: 100,
            previewMenuHeight: 500,
            storyMenuTitleLength: -1,
            showMenuBarIcon: false,
            showUnreadCountInMenuBar: false,
            showUnreadCountInFeeds: false,
            showGlobalUpdateAll: false,
            showGlobalMarkAllRead: false,
            showGlobalMarkAllUnread: false,
            showGlobalShowAllUnread: false
        )
        store.updateAdBlocking(
            enabled: true,
            listURLString: WebAdBlocker.defaultListURLString,
            supplementaryRules: "n1info.rs##.ad-loading-placeholder"
        )

        let restored = FeedStore(defaults: defaults)
        XCTAssertFalse(restored.isFreshInstall)
        XCTAssertEqual(restored.globalRefreshMinutes, 0)
        XCTAssertEqual(restored.previewMarkReadDelaySeconds, 0)
        XCTAssertEqual(restored.previewMenuWidth, 240)
        XCTAssertEqual(restored.previewMenuHeight, 500)
        XCTAssertEqual(restored.storyMenuTitleLength, 0)
        XCTAssertFalse(restored.notificationsEnabled)
        XCTAssertFalse(restored.showGlobalShowAllUnread)
        XCTAssertTrue(restored.adBlockingEnabled)
        XCTAssertEqual(restored.supplementaryAdBlockRules, "n1info.rs##.ad-loading-placeholder")
    }

    func testItemsPersistInOrderWithSeparators() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FeedStore(defaults: defaults)
        store.addFeed(url: try XCTUnwrap(URL(string: "https://one.example/rss")), name: "One")
        store.addSeparator(title: "Group")
        store.addFeed(url: try XCTUnwrap(URL(string: "https://two.example/rss")), name: "Two", refreshMinutes: 5)

        let restored = FeedStore(defaults: defaults)

        XCTAssertEqual(restored.items, store.items)
        XCTAssertEqual(restored.feeds.map(\.name), ["One", "Two"])
    }

    func testMoveItemsPreservesSelectionOrderAndCalculatesInsertionIndex() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FeedStore(defaults: defaults)
        for value in ["A", "B", "C", "D", "E"] {
            store.addFeed(url: try XCTUnwrap(URL(string: "https://example.com/\(value)")), name: value)
        }

        XCTAssertEqual(store.moveItems(at: IndexSet([1, 3]), to: 5), 3)
        XCTAssertEqual(store.feeds.map(\.name), ["A", "C", "E", "B", "D"])
        XCTAssertNil(store.moveItems(at: IndexSet([3, 4]), to: 5))
        XCTAssertNil(store.moveItems(at: IndexSet([99]), to: 0))
    }

    func testImportAddsNewFeedsAndUpdatesCanonicalDuplicates() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FeedStore(defaults: defaults)
        store.addFeed(url: try XCTUnwrap(URL(string: "https://EXAMPLE.com:443/rss#old")), name: "Old")
        let existingID = try XCTUnwrap(store.feeds.first?.id)

        let result = store.importFeeds([
            Feed(id: UUID(), name: "Updated", url: try XCTUnwrap(URL(string: "https://example.com/rss")), refreshMinutes: nil, iconURL: nil),
            Feed(id: UUID(), name: "New", url: try XCTUnwrap(URL(string: "https://new.example/feed")), refreshMinutes: nil, iconURL: nil)
        ])

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(store.feeds.map(\.name), ["Updated", "New"])
        XCTAssertEqual(store.feeds.first?.id, existingID)
    }

    func testReadStateIsScopedByFeedPersistsAndNotifiesOnlyOnChanges() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FeedStore(defaults: defaults)
        let feedOne = UUID()
        let storyOne = FeedStory(id: "shared-id", title: "One", link: nil, summary: "", publishedAt: nil, sourceFeedID: feedOne)
        let storyTwo = FeedStory(id: "shared-id", title: "Two", link: nil, summary: "", publishedAt: nil, sourceFeedID: UUID())
        var notifications = 0
        let observer = store.observe { notifications += 1 }
        defer { store.removeObserver(id: observer) }

        XCTAssertTrue(store.markStory(storyOne, read: true))
        XCTAssertFalse(store.markStory(storyOne, read: true))
        XCTAssertTrue(store.isStoryRead(storyOne))
        XCTAssertFalse(store.isStoryRead(storyTwo))
        XCTAssertEqual(store.unreadStories(in: [storyOne, storyTwo]), [storyTwo])
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(FeedStore(defaults: defaults).isStoryRead(storyOne))
        XCTAssertTrue(store.markStory(storyOne, read: false))
        XCTAssertEqual(notifications, 2)
    }

    func testLegacyFeedsStateMigratesToItemsAndRetiredAdBlockListIsDisabled() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let feed = Feed(id: UUID(), name: "Legacy", url: try XCTUnwrap(URL(string: "https://example.com/rss")), refreshMinutes: nil, iconURL: nil)
        let feedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feed))
        let state: [String: Any] = [
            "globalRefreshMinutes": 20,
            "feeds": [feedJSON],
            "adBlockingEnabled": true,
            "adBlockListURLString": "https://raw.githubusercontent.com/stribor/MicroRSS/master/Filters/easylist.json",
            "previewMenuWidth": 0,
            "previewMenuHeight": 100
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: state), forKey: "MicroRSS.FeedStore.v1")

        let store = FeedStore(defaults: defaults)

        XCTAssertEqual(store.feeds, [feed])
        XCTAssertEqual(store.items, [.feed(feed)])
        XCTAssertFalse(store.adBlockingEnabled)
        XCTAssertEqual(store.adBlockListURLString, WebAdBlocker.defaultListURLString)
        XCTAssertEqual(store.previewMenuWidth, 240)
        XCTAssertEqual(store.previewMenuHeight, 240)
    }
}
