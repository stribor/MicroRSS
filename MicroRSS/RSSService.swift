import Foundation

final class RSSService: NSObject, @unchecked Sendable {
    enum RSSServiceError: Error {
        case invalidResponse
    }

    func fetch(feed: Feed) async throws -> ([FeedStory], FeedMetadata) {
        let (data, response) = try await URLSession.shared.data(from: feed.url)
        guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode else {
            throw RSSServiceError.invalidResponse
        }

        let parser = FeedXMLParser(feedID: feed.id, feedURL: feed.url, data: data)
        return try parser.parse()
    }
}

struct FeedMetadata {
    var title: String?
    var siteURL: URL?
    var iconURL: URL?
}

private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private let feedID: UUID
    private let feedURL: URL
    private let parser: XMLParser

    private var stories: [FeedStory] = []
    private var metadata = FeedMetadata(title: nil, siteURL: nil, iconURL: nil)
    private var currentElementStack: [String] = []
    private var text = ""
    private var inItem = false
    private var itemTitle = ""
    private var itemLink = ""
    private var itemSummary = ""
    private var itemID = ""
    private var itemDate = ""

    init(feedID: UUID, feedURL: URL, data: Data) {
        self.feedID = feedID
        self.feedURL = feedURL
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() throws -> ([FeedStory], FeedMetadata) {
        guard parser.parse() else {
            throw parser.parserError ?? RSSService.RSSServiceError.invalidResponse
        }
        return (stories, metadata)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName.lowercased()
        currentElementStack.append(element)
        text = ""

        if element == "item" || element == "entry" {
            inItem = true
            itemTitle = ""
            itemLink = ""
            itemSummary = ""
            itemID = ""
            itemDate = ""
        }

        if inItem, element == "link", let href = attributeDict["href"], itemLink.isEmpty {
            itemLink = href
        }

        if !inItem, element == "link", let href = attributeDict["href"], metadata.siteURL == nil {
            metadata.siteURL = URL(string: href, relativeTo: feedURL)?.absoluteURL
        }

        if !inItem, (element == "icon" || element == "logo"), let href = attributeDict["href"] {
            metadata.iconURL = URL(string: href, relativeTo: feedURL)?.absoluteURL
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch element {
            case "title":
                itemTitle += value
            case "link":
                if itemLink.isEmpty { itemLink = value }
            case "description", "summary", "content", "content:encoded":
                if itemSummary.isEmpty { itemSummary = value }
            case "guid", "id":
                itemID = value
            case "pubdate", "published", "updated", "dc:date":
                itemDate = value
            case "item", "entry":
                finishItem()
                inItem = false
            default:
                break
            }
        } else {
            switch element {
            case "title":
                if metadata.title == nil, !value.isEmpty { metadata.title = value }
            case "link":
                if metadata.siteURL == nil, !value.isEmpty {
                    metadata.siteURL = URL(string: value, relativeTo: feedURL)?.absoluteURL
                }
            case "icon", "logo":
                if metadata.iconURL == nil, !value.isEmpty {
                    metadata.iconURL = URL(string: value, relativeTo: feedURL)?.absoluteURL
                }
            default:
                break
            }
        }

        if !currentElementStack.isEmpty {
            currentElementStack.removeLast()
        }
        text = ""
    }

    private func finishItem() {
        let title = itemTitle.isEmpty ? "Untitled" : itemTitle
        let link = URL(string: itemLink, relativeTo: feedURL)?.absoluteURL
        let id = itemID.isEmpty ? (link?.absoluteString ?? "\(feedID.uuidString)-\(stories.count)") : itemID
        let story = FeedStory(
            id: id,
            title: title,
            link: link,
            summary: itemSummary,
            publishedAt: DateParser.parse(itemDate),
            sourceFeedID: feedID
        )
        stories.append(story)
    }
}

private enum DateParser {
    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value) ?? rfc822.date(from: value)
    }
}
