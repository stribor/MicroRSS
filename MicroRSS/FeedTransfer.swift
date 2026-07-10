import Foundation

struct FeedImportResult {
    var added: Int
    var updated: Int
}

enum FeedTransferError: LocalizedError {
    case invalidOPML
    case noFeeds

    var errorDescription: String? {
        switch self {
        case .invalidOPML:
            return "The selected file is not valid OPML."
        case .noFeeds:
            return "The selected OPML file does not contain any feeds."
        }
    }
}

enum FeedTransfer {
    static func exportOPML(feeds: [Feed]) -> Data {
        let outlines = feeds.map { feed in
            var attributes = [
                "type=\"rss\"",
                "text=\"\(xmlEscaped(feed.displayName))\"",
                "title=\"\(xmlEscaped(feed.name))\"",
                "xmlUrl=\"\(xmlEscaped(feed.url.absoluteString))\""
            ]
            if let refreshMinutes = feed.refreshMinutes {
                attributes.append("microRSSRefreshMinutes=\"\(refreshMinutes)\"")
            }
            return "    <outline \(attributes.joined(separator: " ")) />"
        }.joined(separator: "\n")

        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>MicroRSS Feeds</title>
          </head>
          <body>
        \(outlines)
          </body>
        </opml>
        """
        return Data(document.utf8)
    }

    static func importOPML(data: Data) throws -> [Feed] {
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawOPML else {
            throw parser.parserError ?? FeedTransferError.invalidOPML
        }
        guard !delegate.feeds.isEmpty else { throw FeedTransferError.noFeeds }
        return delegate.feeds
    }

    static func canonicalURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "http" && components.port == 80) ||
            (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path == "/" { components.path = "" }
        return components.string ?? url.absoluteString
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var feeds: [Feed] = []
    var sawOPML = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName.caseInsensitiveCompare("opml") == .orderedSame {
            sawOPML = true
            return
        }
        guard elementName.caseInsensitiveCompare("outline") == .orderedSame,
              let urlString = attribute(attributeDict, named: "xmlUrl")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString) else { return }

        let title = attribute(attributeDict, named: "title")
            ?? attribute(attributeDict, named: "text")
            ?? ""
        let refreshMinutes = attribute(attributeDict, named: "microRSSRefreshMinutes").flatMap(Int.init)
        feeds.append(Feed(
            id: UUID(),
            name: title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url,
            refreshMinutes: refreshMinutes.map { max(0, $0) },
            iconURL: nil
        ))
    }

    private func attribute(_ attributes: [String: String], named name: String) -> String? {
        attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
