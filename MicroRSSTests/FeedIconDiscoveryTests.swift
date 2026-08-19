import XCTest
@testable import MicroRSS

final class FeedIconDiscoveryTests: XCTestCase {
    func testFindsRelativeAndAbsoluteIconLinks() throws {
        let html = """
        <html><head>
        <link rel="icon" sizes="32x32" href="/images/icon.png">
        <link href='https://cdn.example.com/touch.png' rel='apple-touch-icon'>
        </head></html>
        """

        let urls = FeedIconDiscovery.iconURLs(
            in: html,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/news/"))
        )

        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/images/icon.png",
            "https://cdn.example.com/touch.png"
        ])
    }

    func testIgnoresNonIconLinksAndDeduplicatesIcons() throws {
        let html = """
        <link rel="stylesheet" href="style.css">
        <link rel="shortcut icon" href="favicon.ico">
        <link rel="icon" href="favicon.ico">
        """

        let urls = FeedIconDiscovery.iconURLs(
            in: html,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/feeds/main"))
        )

        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/feeds/favicon.ico"])
    }
}
