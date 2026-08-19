import XCTest
@testable import MicroRSS

final class ModelsAndTransferTests: XCTestCase {
    func testDisplayNamesTrimWhitespaceAndFallBackCleanly() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))
        XCTAssertEqual(Feed(id: UUID(), name: "  News \n", url: url, refreshMinutes: nil, iconURL: nil).displayName, "News")
        XCTAssertEqual(Feed(id: UUID(), name: " \n", url: url, refreshMinutes: nil, iconURL: nil).displayName, "example.com")
        XCTAssertEqual(FeedSeparator(id: UUID(), title: " \t").displayName, "Separator")
    }

    func testFeedListItemsRoundTripThroughCodable() throws {
        let items: [FeedListItem] = [
            .feed(Feed(
                id: UUID(),
                name: "Example",
                url: try XCTUnwrap(URL(string: "https://example.com/rss")),
                refreshMinutes: 15,
                iconURL: try XCTUnwrap(URL(string: "https://example.com/icon.png"))
            )),
            .separator(FeedSeparator(id: UUID(), title: "Tech"))
        ]

        let decoded = try JSONDecoder().decode([FeedListItem].self, from: JSONEncoder().encode(items))

        XCTAssertEqual(decoded, items)
        XCTAssertEqual(decoded.compactMap(\.feed).count, 1)
    }

    func testOPMLRoundTripPreservesEscapedNamesURLsAndRefreshIntervals() throws {
        let feeds = [
            Feed(
                id: UUID(),
                name: "News & <Views> \"Daily\"",
                url: try XCTUnwrap(URL(string: "https://example.com/feed?category=a%26b")),
                refreshMinutes: 45,
                iconURL: nil
            ),
            Feed(
                id: UUID(),
                name: "No Override",
                url: try XCTUnwrap(URL(string: "https://other.example/rss")),
                refreshMinutes: nil,
                iconURL: nil
            )
        ]

        let imported = try FeedTransfer.importOPML(data: FeedTransfer.exportOPML(feeds: feeds))

        XCTAssertEqual(imported.map(\.name), feeds.map(\.name))
        XCTAssertEqual(imported.map(\.url), feeds.map(\.url))
        XCTAssertEqual(imported.map(\.refreshMinutes), feeds.map(\.refreshMinutes))
    }

    func testOPMLImportHandlesCaseInsensitiveAttributesAndClampsRefresh() throws {
        let data = Data("""
        <OPML version="2.0"><body>
          <outline XMLURL="https://example.com/rss" TEXT=" Example " MICRORSSREFRESHMINUTES="-5" />
          <outline text="Folder"><outline xmlUrl="https://nested.example/feed" title="Nested" /></outline>
        </body></OPML>
        """.utf8)

        let feeds = try FeedTransfer.importOPML(data: data)

        XCTAssertEqual(feeds.map(\.name), ["Example", "Nested"])
        XCTAssertEqual(feeds.map(\.refreshMinutes), [0, nil])
    }

    func testOPMLImportReportsInvalidAndEmptyDocuments() {
        XCTAssertThrowsError(try FeedTransfer.importOPML(data: Data("not xml".utf8)))
        XCTAssertThrowsError(try FeedTransfer.importOPML(data: Data("<opml><body /></opml>".utf8))) { error in
            guard case FeedTransferError.noFeeds = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCanonicalURLNormalizesOnlyEquivalentURLParts() throws {
        let url = try XCTUnwrap(URL(string: "HTTPS://Example.COM:443/path/?q=1#section"))
        let root = try XCTUnwrap(URL(string: "http://EXAMPLE.com:80/"))

        XCTAssertEqual(FeedTransfer.canonicalURL(url), "https://example.com/path/?q=1")
        XCTAssertEqual(FeedTransfer.canonicalURL(root), "http://example.com")
    }
}
