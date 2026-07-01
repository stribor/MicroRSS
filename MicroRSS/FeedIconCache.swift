import AppKit

@MainActor
final class FeedIconCache {
    static let didResetNotification = Notification.Name("MicroRSS.FeedIconCache.didReset")

    private let cacheDirectory: URL
    private var imagesByFeedID: [UUID: NSImage] = [:]
    private var activeFetches: Set<UUID> = []
    private var resetObserver: NSObjectProtocol?
    var didUpdate: (() -> Void)?

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

    func notificationAttachmentURL(for feed: Feed) -> URL? {
        guard let image = image(for: feed),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let url = cacheDirectory.appendingPathComponent("\(feed.id.uuidString)-notification.png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
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
    }

    private func fetchImageIfNeeded(for feed: Feed) {
        guard let iconURL = feed.iconURL, activeFetches.insert(feed.id).inserted else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { activeFetches.remove(feed.id) }

            do {
                let (data, response) = try await URLSession.shared.data(from: iconURL)
                guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode,
                      let image = NSImage(data: data) else { return }
                try? data.write(to: cachedFileURL(for: feed.id), options: .atomic)
                imagesByFeedID[feed.id] = image
                didUpdate?()
            } catch {
                return
            }
        }
    }

    private func loadCachedImage(for feedID: UUID) -> NSImage? {
        NSImage(contentsOf: cachedFileURL(for: feedID))
    }

    private func cachedFileURL(for feedID: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(feedID.uuidString).img")
    }
}
