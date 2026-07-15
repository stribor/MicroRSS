import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchCompletedKey = "MicroRSS.FirstLaunchCompleted"
    private var statusController: StatusMenuController?
    private var dockIconController: DockIconController?
    private var shouldInitialize = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let existingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentProcessIdentifier }) else {
            return
        }

        shouldInitialize = false
        existingApplication.activate(options: [])
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldInitialize else { return }
        NSApp.mainMenu = ApplicationMenu.make()
        let store = FeedStore()
        let service = RSSService()
        dockIconController = DockIconController(store: store)
        statusController = StatusMenuController(store: store, service: service)

        let defaults = UserDefaults.standard
        if store.isFreshInstall && !defaults.bool(forKey: firstLaunchCompletedKey) {
            defaults.set(true, forKey: firstLaunchCompletedKey)
            DispatchQueue.main.async { [weak self] in
                self?.statusController?.showSettings()
            }
        }
    }
}

@MainActor
private final class DockIconController: NSObject {
    private let store: FeedStore
    private var storeObserverID: UUID?

    init(store: FeedStore) {
        self.store = store
        super.init()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowVisibilityDidChange), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowVisibilityDidChange), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        storeObserverID = store.observe { [weak self] in
            self?.updateActivationPolicy()
        }
        updateActivationPolicy()
    }

    deinit {
        let observerID = storeObserverID
        let observedStore = store
        NotificationCenter.default.removeObserver(self)
        if let observerID {
            MainActor.assumeIsolated {
                observedStore.removeObserver(id: observerID)
            }
        }
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        guard notification.name == NSWindow.didBecomeKeyNotification else {
            scheduleActivationPolicyUpdate()
            return
        }
        updateActivationPolicy()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        scheduleActivationPolicyUpdate()
    }

    private func scheduleActivationPolicyUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let hasOpenWindow = NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled)
        }
        let policy: NSApplication.ActivationPolicy = store.hideDockIcon && !hasOpenWindow ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

enum ApplicationMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        return mainMenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "MicroRSS")
        menu.addItem(NSMenuItem(title: "Quit MicroRSS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        menu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        item.submenu = menu
        return item
    }
}
