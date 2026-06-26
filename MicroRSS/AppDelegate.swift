import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = FeedStore()
        let service = RSSService()
        statusController = StatusMenuController(store: store, service: service)
    }
}
