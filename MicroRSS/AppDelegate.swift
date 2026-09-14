import AppKit
import Carbon.HIToolbox
import OSLog

private let editingCommandLogger = Logger(subsystem: "org.stribor.microrss", category: "InlineCopy")
private let editingHotKeySignature: OSType = 0x4D_52_53_53 // MRSS

private func handleEditingHotKey(
    _ handlerCall: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == editingHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let router = Unmanaged<EditingCommandRouter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        router.performHotKey(id: identifier.id)
    }
    return noErr
}

enum BuildInfo {
    static let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    static let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    static let gitCommit: String? = {
        guard let url = Bundle.main.url(forResource: "GitCommit", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let commit = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }()

    static var versionDescription: String {
        var description = "\(shortVersion) (\(buildVersion))"
        if let gitCommit {
            description += " · \(gitCommit)"
        }
        return description
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchCompletedKey = "MicroRSS.FirstLaunchCompleted"
    private var statusController: StatusMenuController?
    private var dockIconController: DockIconController?
    private var shouldInitialize = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
protocol EditingCommandTarget: AnyObject {
    func cutSelection()
    func copySelection()
    func pasteClipboard()
    func selectAllContent()
}

@MainActor
final class EditingCommandRouter: NSObject, NSMenuItemValidation {
    static let shared = EditingCommandRouter()
    weak var inlineTarget: (any EditingCommandTarget)?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]

    override init() {
        super.init()
        installHotKeyHandler()
    }

    func beginInlineSession(target: any EditingCommandTarget) {
        inlineTarget = target
        registerInlineHotKeys()
    }

    func endInlineHotKeyInterception() {
        for hotKey in hotKeys.values {
            UnregisterEventHotKey(hotKey)
        }
        if !hotKeys.isEmpty {
            editingCommandLogger.notice("Unregistered inline editing hotkeys")
        }
        hotKeys.removeAll()
    }

    func clearInlineTarget(_ target: any EditingCommandTarget) {
        if inlineTarget === target {
            inlineTarget = nil
        }
    }

    @objc func cut(_ sender: Any?) {
        guard let inlineTarget else {
            forward(#selector(NSText.cut(_:)), sender: sender)
            return
        }
        inlineTarget.cutSelection()
    }

    @objc func copy(_ sender: Any?) {
        editingCommandLogger.notice("Global Edit copy action dispatched; inline target: \(self.inlineTarget != nil, privacy: .public)")
        guard let inlineTarget else {
            forward(#selector(NSText.copy(_:)), sender: sender)
            return
        }
        inlineTarget.copySelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let inlineTarget else {
            forward(#selector(NSText.paste(_:)), sender: sender)
            return
        }
        inlineTarget.pasteClipboard()
    }

    @objc func selectAll(_ sender: Any?) {
        guard let inlineTarget else {
            forward(#selector(NSText.selectAll(_:)), sender: sender)
            return
        }
        inlineTarget.selectAllContent()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if inlineTarget != nil { return true }
        guard let action = menuItem.action else { return false }
        return NSApp.target(forAction: action, to: nil, from: menuItem) != nil
    }

    private func forward(_ action: Selector, sender: Any?) {
        NSApp.sendAction(action, to: nil, from: sender)
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handleEditingHotKey,
            1,
            &eventType,
            userData,
            &hotKeyHandler
        )
        if status != noErr {
            editingCommandLogger.error("Failed to install editing hotkey handler: \(status, privacy: .public)")
        }
    }

    private func registerInlineHotKeys() {
        guard hotKeys.isEmpty else { return }
        let shortcuts: [(id: HotKeyID, keyCode: UInt32)] = [
            (.cut, UInt32(kVK_ANSI_X)),
            (.copy, UInt32(kVK_ANSI_C)),
            (.paste, UInt32(kVK_ANSI_V)),
            (.selectAll, UInt32(kVK_ANSI_A))
        ]

        for shortcut in shortcuts {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: editingHotKeySignature, id: shortcut.id.rawValue)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                UInt32(cmdKey),
                identifier,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &reference
            )
            if status == noErr, let reference {
                hotKeys[shortcut.id.rawValue] = reference
                editingCommandLogger.notice("Registered inline hotkey id \(shortcut.id.rawValue, privacy: .public)")
            } else {
                editingCommandLogger.error("Failed to register inline hotkey id \(shortcut.id.rawValue, privacy: .public): \(status, privacy: .public)")
            }
        }
    }

    fileprivate func performHotKey(id: UInt32) {
        guard let command = HotKeyID(rawValue: id), let inlineTarget else { return }
        editingCommandLogger.notice("Received inline hotkey id \(id, privacy: .public)")
        switch command {
        case .cut: inlineTarget.cutSelection()
        case .copy: inlineTarget.copySelection()
        case .paste: inlineTarget.pasteClipboard()
        case .selectAll: inlineTarget.selectAllContent()
        }
    }

    private enum HotKeyID: UInt32 {
        case cut = 1
        case copy
        case paste
        case selectAll
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

@MainActor
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
        let router = EditingCommandRouter.shared

        menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        menu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        menu.addItem(.separator())
        let cut = NSMenuItem(title: "Cut", action: #selector(EditingCommandRouter.cut(_:)), keyEquivalent: "x")
        cut.target = router
        menu.addItem(cut)
        let copy = NSMenuItem(title: "Copy", action: #selector(EditingCommandRouter.copy(_:)), keyEquivalent: "c")
        copy.target = router
        menu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(EditingCommandRouter.paste(_:)), keyEquivalent: "v")
        paste.target = router
        menu.addItem(paste)
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let selectAll = NSMenuItem(title: "Select All", action: #selector(EditingCommandRouter.selectAll(_:)), keyEquivalent: "a")
        selectAll.target = router
        menu.addItem(selectAll)

        item.submenu = menu
        return item
    }
}
