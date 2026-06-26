import Foundation

struct Feed: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: URL
    var refreshMinutes: Int?
    var iconURL: URL?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.host(percentEncoded: false) ?? url.absoluteString : trimmed
    }
}

struct FeedSeparator: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String

    var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Separator" : trimmed
    }
}

enum FeedListItem: Codable, Identifiable, Equatable {
    case feed(Feed)
    case separator(FeedSeparator)

    private enum CodingKeys: String, CodingKey {
        case kind
        case feed
        case separator
    }

    private enum Kind: String, Codable {
        case feed
        case separator
    }

    var id: UUID {
        switch self {
        case .feed(let feed):
            return feed.id
        case .separator(let separator):
            return separator.id
        }
    }

    var feed: Feed? {
        guard case .feed(let feed) = self else { return nil }
        return feed
    }

    init(feed: Feed) {
        self = .feed(feed)
    }

    init(separator: FeedSeparator) {
        self = .separator(separator)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .feed:
            self = .feed(try container.decode(Feed.self, forKey: .feed))
        case .separator:
            self = .separator(try container.decode(FeedSeparator.self, forKey: .separator))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .feed(let feed):
            try container.encode(Kind.feed, forKey: .kind)
            try container.encode(feed, forKey: .feed)
        case .separator(let separator):
            try container.encode(Kind.separator, forKey: .kind)
            try container.encode(separator, forKey: .separator)
        }
    }
}

struct FeedStory: Identifiable, Equatable {
    var id: String
    var title: String
    var link: URL?
    var summary: String
    var publishedAt: Date?
    var sourceFeedID: UUID
}

struct FeedStoryContext {
    var story: FeedStory
    var feed: Feed
}
