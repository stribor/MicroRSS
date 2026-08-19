import XCTest
@testable import MicroRSS

final class RSSServiceTests: XCTestCase {
    func testParsesRSSMetadataStoriesRelativeLinksAndRFC822Dates() throws {
        let feedID = UUID()
        let xml = """
        <rss version="2.0"><channel>
          <title>Example News</title>
          <description>Daily updates</description>
          <link>https://example.com/</link>
          <image><url>/images/feed.png</url></image>
          <item>
            <title>First story</title>
            <link>/articles/1</link>
            <guid>story-1</guid>
            <description><![CDATA[<p>Summary</p>]]></description>
            <pubDate>Tue, 18 Aug 2026 09:30:00 +0200</pubDate>
          </item>
        </channel></rss>
        """

        let (stories, metadata) = try FeedXMLParser(
            feedID: feedID,
            feedURL: try XCTUnwrap(URL(string: "https://example.com/feed.xml")),
            data: Data(xml.utf8)
        ).parse()

        XCTAssertEqual(metadata.title, "Example News")
        XCTAssertEqual(metadata.description, "Daily updates")
        XCTAssertEqual(metadata.siteURL?.absoluteString, "https://example.com/")
        XCTAssertEqual(metadata.iconURL?.absoluteString, "https://example.com/images/feed.png")
        XCTAssertEqual(stories.count, 1)
        XCTAssertEqual(stories[0].id, "story-1")
        XCTAssertEqual(stories[0].link?.absoluteString, "https://example.com/articles/1")
        XCTAssertEqual(stories[0].summary, "<p>Summary</p>")
        XCTAssertEqual(stories[0].sourceFeedID, feedID)
        XCTAssertNotNil(stories[0].publishedAt)
    }

    func testParsesAtomAlternateLinkIconAndISODate() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed</title>
          <link rel="self" href="https://example.com/atom.xml" />
          <link rel="alternate" href="https://example.com/home" />
          <link rel="icon" href="/icon.svg" />
          <entry>
            <title>Atom story</title>
            <link href="article" />
            <id>tag:example.com,2026:1</id>
            <summary>Atom summary</summary>
            <updated>2026-08-18T07:30:00Z</updated>
          </entry>
        </feed>
        """

        let (stories, metadata) = try FeedXMLParser(
            feedID: UUID(),
            feedURL: try XCTUnwrap(URL(string: "https://example.com/feeds/atom.xml")),
            data: Data(xml.utf8)
        ).parse()

        XCTAssertEqual(metadata.siteURL?.absoluteString, "https://example.com/home")
        XCTAssertEqual(metadata.iconURL?.absoluteString, "https://example.com/icon.svg")
        XCTAssertEqual(stories.first?.link?.absoluteString, "https://example.com/feeds/article")
        XCTAssertEqual(stories.first?.id, "tag:example.com,2026:1")
        XCTAssertNotNil(stories.first?.publishedAt)
    }

    func testMissingStoryFieldsUseStableFallbacks() throws {
        let feedID = UUID()
        let xml = "<rss><channel><item><description>Only summary</description></item></channel></rss>"

        let (stories, _) = try FeedXMLParser(
            feedID: feedID,
            feedURL: try XCTUnwrap(URL(string: "https://example.com/feed")),
            data: Data(xml.utf8)
        ).parse()

        XCTAssertEqual(stories.first?.title, "Untitled")
        XCTAssertEqual(stories.first?.id, "\(feedID.uuidString)-0")
        XCTAssertNil(stories.first?.link)
        XCTAssertNil(stories.first?.publishedAt)
    }

    func testMalformedXMLThrows() throws {
        let parser = FeedXMLParser(
            feedID: UUID(),
            feedURL: try XCTUnwrap(URL(string: "https://example.com/feed")),
            data: Data("<rss><channel>".utf8)
        )
        XCTAssertThrowsError(try parser.parse())
    }

    func testDateParserSupportsISO8601RFC822AndRejectsInvalidValues() {
        XCTAssertNotNil(DateParser.parse("2026-08-18T07:30:00Z"))
        XCTAssertNotNil(DateParser.parse("Tue, 18 Aug 2026 09:30:00 +0200"))
        XCTAssertNil(DateParser.parse("not a date"))
        XCTAssertNil(DateParser.parse(""))
    }
}
