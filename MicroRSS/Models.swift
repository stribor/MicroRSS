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
