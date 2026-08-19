import AppKit

@MainActor
final class FeedIconCache {
    static let didResetNotification = Notification.Name("MicroRSS.FeedIconCache.didReset")

    private let cacheDirectory: URL
    private var imagesByFeedID: [UUID: NSImage] = [:]
    private var activeFetches: Set<UUID> = []
    private var failedFetchSignatures: [UUID: String] = [:]
    private var resetObserver: NSObjectProtocol?
    var didUpdate: (() -> Void)?
    var didResolveIconURL: ((UUID, URL) -> Void)?

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        cacheDirectory = baseURL.appendingPathComponent("MicroRSS/FaviconCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        resetObserver = NotificationCenter.default.addObserver(
            forName: Self.didResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearMemory()
                self?.didUpdate?()
            }
        }
    }

    func image(for feed: Feed) -> NSImage? {
        if let image = imagesByFeedID[feed.id] {
            return image
        }

        if let cached = loadCachedImage(for: feed.id) {
            imagesByFeedID[feed.id] = cached
            return cached
        }

        fetchImageIfNeeded(for: feed)
        return nil
    }

    func reset() {
        clearMemory()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        didUpdate?()
        NotificationCenter.default.post(name: Self.didResetNotification, object: nil)
    }

    private func clearMemory() {
        imagesByFeedID.removeAll()
        activeFetches.removeAll()
        failedFetchSignatures.removeAll()
    }

    private func fetchImageIfNeeded(for feed: Feed) {
        let signature = "\(feed.url.absoluteString)|\(feed.iconURL?.absoluteString ?? "")"
        guard failedFetchSignatures[feed.id] != signature,
              activeFetches.insert(feed.id).inserted else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { activeFetches.remove(feed.id) }

            guard let result = await resolvedImage(for: feed) else {
                failedFetchSignatures[feed.id] = signature
                return
            }

            failedFetchSignatures[feed.id] = nil
            try? result.data.write(to: cachedFileURL(for: feed.id), options: .atomic)
            imagesByFeedID[feed.id] = result.image
            if result.url != feed.iconURL {
                didResolveIconURL?(feed.id, result.url)
            }
            didUpdate?()
        }
    }

    private func resolvedImage(for feed: Feed) async -> (data: Data, image: NSImage, url: URL)? {
        var candidates: [URL] = []
        appendUnique(feed.iconURL, to: &candidates)

        let siteURL = rootURL(for: feed.url)
        if let siteURL {
            for url in await declaredIconURLs(at: siteURL) {
                appendUnique(url, to: &candidates)
            }
            appendUnique(URL(string: "favicon.ico", relativeTo: siteURL)?.absoluteURL, to: &candidates)
        }

        for url in candidates {
            if let image = await loadImage(at: url) {
                return (image.data, image.image, url)
            }
        }

        if let fallbackURL = cachedFaviconURL(for: siteURL),
           let image = await loadImage(at: fallbackURL) {
            return (image.data, image.image, fallbackURL)
        }

        return nil
    }

    private func declaredIconURLs(at siteURL: URL) async -> [URL] {
        do {
            let (data, response) = try await URLSession.shared.data(from: siteURL)
            guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode,
                  let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return [] }
            return FeedIconDiscovery.iconURLs(in: html, baseURL: response.url ?? siteURL)
        } catch {
            return []
        }
    }

    private func loadImage(at url: URL) async -> (data: Data, image: NSImage)? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode,
                  let image = NSImage(data: data) else { return nil }
            return (data, image)
        } catch {
            return nil
        }
    }

    private func rootURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme != nil, components.host != nil else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func cachedFaviconURL(for siteURL: URL?) -> URL? {
        guard let host = siteURL?.host(percentEncoded: false), !host.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "64")
        ]
        return components?.url
    }

    private func appendUnique(_ url: URL?, to urls: inout [URL]) {
        guard let url, !urls.contains(url) else { return }
        urls.append(url)
    }

    private func loadCachedImage(for feedID: UUID) -> NSImage? {
        NSImage(contentsOf: cachedFileURL(for: feedID))
    }

    private func cachedFileURL(for feedID: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(feedID.uuidString).img")
    }
}

enum FeedIconDiscovery {
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"<link\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: []
    )

    static func iconURLs(in html: String, baseURL: URL) -> [URL] {
        let fullRange = NSRange(html.startIndex..., in: html)
        var urls: [URL] = []

        for match in linkPattern.matches(in: html, range: fullRange) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[tagRange]))
            guard attributes["rel"]?.lowercased().contains("icon") == true,
                  let href = attributes["href"],
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  !urls.contains(url) else { continue }
            urls.append(url)
        }

        return urls
    }

    private static func attributes(in tag: String) -> [String: String] {
        let fullRange = NSRange(tag.startIndex..., in: tag)
        var attributes: [String: String] = [:]

        for match in attributePattern.matches(in: tag, range: fullRange) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let valueRange = (2...4)
                .lazy
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
            guard let valueRange, let swiftValueRange = Range(valueRange, in: tag) else { continue }
            attributes[String(tag[nameRange]).lowercased()] = String(tag[swiftValueRange])
        }

        return attributes
    }
}
