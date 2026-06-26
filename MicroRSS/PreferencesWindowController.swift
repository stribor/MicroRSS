import AppKit
import ServiceManagement

@MainActor
final class PreferencesWindowController: NSWindowController {
    private enum TabID {
        static let feeds = "feeds"
        static let general = "general"
        static let about = "about"
    }

    private enum ToolbarID {
        static let feeds = NSToolbarItem.Identifier("feeds")
        static let general = NSToolbarItem.Identifier("general")
        static let about = NSToolbarItem.Identifier("about")
    }

    private let store: FeedStore
    private let iconCache = FeedIconCache()
    private let feedRowPasteboardType = NSPasteboard.PasteboardType("com.ivang.MicroRSS.feed-list-row")
    private let tabView = NSTabView()
    private let tableView = NSTableView()
    private let removeItemButton = NSButton(title: "-", target: nil, action: nil)
    private let moveUpButton = NSButton(title: "Up", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "Down", target: nil, action: nil)
    private let globalRefreshField = NSTextField()
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let notificationsButton = NSButton(checkboxWithTitle: "Show notifications for new articles", target: nil, action: nil)
    private let statusHighlightButton = NSButton(checkboxWithTitle: "Dim menu bar icon when all articles are read", target: nil, action: nil)
    private let showMenuBarIconButton = NSButton(checkboxWithTitle: "Show RSS icon in menu bar", target: nil, action: nil)
    private let showMenuBarUnreadCountButton = NSButton(checkboxWithTitle: "Show unread count in menu bar", target: nil, action: nil)
    private let showFeedUnreadCountButton = NSButton(checkboxWithTitle: "Show unread count in feeds", target: nil, action: nil)
    private let globalUpdateAllButton = NSButton(checkboxWithTitle: "Update all feeds", target: nil, action: nil)
    private let globalMarkAllReadButton = NSButton(checkboxWithTitle: "Mark all read", target: nil, action: nil)
    private let globalMarkAllUnreadButton = NSButton(checkboxWithTitle: "Mark all unread", target: nil, action: nil)
    private let globalShowAllUnreadButton = NSButton(checkboxWithTitle: "Show all unread", target: nil, action: nil)
    private let feedCountLabel = NSTextField(labelWithString: "")
    private var selectedItemIDs: [UUID] = []
    private var storeObserverID: UUID?

    init(store: FeedStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MicroRSS Settings"
        window.minSize = NSSize(width: 760, height: 560)
        window.toolbarStyle = .unified
        super.init(window: window)
        configureWindowBackground()
        configureToolbar()
        buildUI()
        configureGeneralActions()
        reloadGeneralSettings()
        reloadSelection()
        iconCache.didUpdate = { [weak self] in
            self?.tableView.reloadData()
        }
        storeObserverID = store.observe { [weak self] in
            self?.reloadGeneralSettings()
            self?.tableView.reloadData()
            self?.reloadSelection()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let storeObserverID {
            MainActor.assumeIsolated {
                store.removeObserver(id: storeObserverID)
            }
        }
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "MicroRSSSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
        window?.toolbar?.selectedItemIdentifier = ToolbarID.feeds
    }

    private func configureWindowBackground() {
        guard let window else { return }

        let effectView = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.isEmphasized = true

        window.appearance = NSAppearance(named: .vibrantDark)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.contentView = effectView
        window.isMovableByWindowBackground = true
    }

    private func buildUI() {
        guard let content = settingsContentView else { return }

        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        tabView.addTabViewItem(tabItem(identifier: TabID.feeds, label: "Feeds", view: buildFeedsPane()))
        tabView.addTabViewItem(tabItem(identifier: TabID.general, label: "General", view: buildGeneralPane()))
        tabView.addTabViewItem(tabItem(identifier: TabID.about, label: "About", view: buildAboutPane()))
        tabView.selectTabViewItem(withIdentifier: TabID.feeds)
    }

    private var settingsContentView: NSView? {
        return window?.contentView
    }

    private func tabItem(identifier: String, label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: identifier)
        item.label = label
        item.view = view
        return item
    }

    private func buildGeneralPane() -> NSView {
        let container = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        globalRefreshField.placeholderString = "30 or Off"
        configureSingleLineField(globalRefreshField)

        let form = NSGridView()
        form.rowSpacing = 12
        form.columnSpacing = 12
        form.addRow(with: [label("Global refresh"), globalRefreshField])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .leading

        let options = NSStackView(views: [launchAtLoginButton, notificationsButton])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 10

        let appearanceTitle = sectionTitle("Appearance")
        let appearanceOptions = NSStackView(views: [
            showMenuBarIconButton,
            showMenuBarUnreadCountButton,
            showFeedUnreadCountButton,
            statusHighlightButton
        ])
        appearanceOptions.orientation = .vertical
        appearanceOptions.alignment = .leading
        appearanceOptions.spacing = 10

        let globalMenuTitle = sectionTitle("Global Menu")
        let globalMenuOptions = NSStackView(views: [
            globalUpdateAllButton,
            globalMarkAllReadButton,
            globalMarkAllUnreadButton,
            globalShowAllUnreadButton
        ])
        globalMenuOptions.orientation = .vertical
        globalMenuOptions.alignment = .leading
        globalMenuOptions.spacing = 10

        let resetIconCacheButton = NSButton(title: "Reset Icon Cache", target: self, action: #selector(resetIconCache))
        resetIconCacheButton.bezelStyle = .rounded

        root.addArrangedSubview(form)
        root.addArrangedSubview(options)
        root.addArrangedSubview(appearanceTitle)
        root.addArrangedSubview(appearanceOptions)
        root.addArrangedSubview(resetIconCacheButton)
        root.addArrangedSubview(globalMenuTitle)
        root.addArrangedSubview(globalMenuOptions)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -28),
            globalRefreshField.widthAnchor.constraint(equalToConstant: 96)
        ])

        return container
    }

    private func configureGeneralActions() {
        globalRefreshField.target = self
        globalRefreshField.action = #selector(applyGeneralSettingsFromControl)
        globalRefreshField.delegate = self

        [
            launchAtLoginButton,
            notificationsButton,
            statusHighlightButton,
            showMenuBarIconButton,
            showMenuBarUnreadCountButton,
            showFeedUnreadCountButton,
            globalUpdateAllButton,
            globalMarkAllReadButton,
            globalMarkAllUnreadButton,
            globalShowAllUnreadButton
        ].forEach { button in
            button.target = self
            button.action = #selector(applyGeneralSettingsFromControl)
        }
    }

    private func buildFeedsPane() -> NSView {
        let container = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        root.addArrangedSubview(buildFeedTable())
        root.addArrangedSubview(buildFeedControls())

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])

        return container
    }

    private func buildAboutPane() -> NSView {
        let container = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "MicroRSS")
        name.font = NSFont.boldSystemFont(ofSize: 24)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.textColor = .secondaryLabelColor

        let description = NSTextField(labelWithString: "A minimal native macOS RSS reader for the menu bar.")
        description.textColor = .secondaryLabelColor

        root.addArrangedSubview(icon)
        root.addArrangedSubview(name)
        root.addArrangedSubview(versionLabel)
        root.addArrangedSubview(description)

        NSLayoutConstraint.activate([
            root.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            root.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            root.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96)
        ])

        return container
    }

    private func buildFeedTable() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false

        tableView.addTableColumn(column("name", title: "Name", width: 230, minWidth: 160))
        tableView.addTableColumn(column("url", title: "URL", width: 520, minWidth: 260))
        tableView.addTableColumn(column("refresh", title: "Refresh", width: 90, minWidth: 72))
        tableView.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.28)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.allowsMultipleSelection = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(editClickedFeedCell)
        tableView.registerForDraggedTypes([feedRowPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = tableView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return scroll
    }

    private func column(_ identifier: String, title: String, width: CGFloat, minWidth: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        return column
    }

    private func buildFeedControls() -> NSView {
        let addButton = NSButton(title: "+", target: self, action: #selector(addFeed))
        let addSeparatorButton = NSButton(title: "Separator", target: self, action: #selector(addSeparator))
        let spacer = NSView()

        removeItemButton.target = self
        removeItemButton.action = #selector(removeSelectedItem)
        moveUpButton.target = self
        moveUpButton.action = #selector(moveFeedUp)
        moveDownButton.target = self
        moveDownButton.action = #selector(moveFeedDown)

        feedCountLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        feedCountLabel.alignment = .center

        let controls = NSStackView(views: [addButton, addSeparatorButton, removeItemButton, moveUpButton, moveDownButton, spacer, feedCountLabel])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        feedCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        let container = NSView()
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controls.topAnchor.constraint(equalTo: container.topAnchor),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])
        return container
    }

    private func configureSingleLineField(_ field: NSTextField) {
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func globalRefreshPlaceholder() -> String {
        store.globalRefreshMinutes == 0 ? "Global: Off" : "Global: \(store.globalRefreshMinutes)m"
    }

    private func reloadGeneralSettings() {
        globalRefreshField.stringValue = refreshDisplayValue(store.globalRefreshMinutes)
        launchAtLoginButton.state = store.launchAtLogin ? .on : .off
        notificationsButton.state = store.notificationsEnabled ? .on : .off
        statusHighlightButton.state = store.highlightUnreadInStatusItem ? .on : .off
        showMenuBarIconButton.state = store.showMenuBarIcon ? .on : .off
        showMenuBarUnreadCountButton.state = store.showUnreadCountInMenuBar ? .on : .off
        showFeedUnreadCountButton.state = store.showUnreadCountInFeeds ? .on : .off
        globalUpdateAllButton.state = store.showGlobalUpdateAll ? .on : .off
        globalMarkAllReadButton.state = store.showGlobalMarkAllRead ? .on : .off
        globalMarkAllUnreadButton.state = store.showGlobalMarkAllUnread ? .on : .off
        globalShowAllUnreadButton.state = store.showGlobalShowAllUnread ? .on : .off
    }

    private func reloadSelection() {
        let separatorCount = store.items.filter {
            if case .separator = $0 { return true }
            return false
        }.count
        let feedText = "\(store.feeds.count) \(store.feeds.count == 1 ? "feed" : "feeds")"
        feedCountLabel.stringValue = separatorCount == 0 ? feedText : "\(feedText), \(separatorCount) \(separatorCount == 1 ? "separator" : "separators")"

        let selectedRows = IndexSet(selectedItemIDs.compactMap { selectedItemID in
            store.items.firstIndex { $0.id == selectedItemID }
        })

        if !selectedRows.isEmpty, tableView.selectedRowIndexes != selectedRows {
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        } else if selectedRows.isEmpty, !selectedItemIDs.isEmpty {
            selectedItemIDs = []
            tableView.deselectAll(nil)
        }

        updateFeedControls()
    }

    private func updateFeedControls() {
        let selectedRows = tableView.selectedRowIndexes.filter { store.items.indices.contains($0) }
        let hasSelection = !selectedRows.isEmpty
        removeItemButton.isEnabled = hasSelection
        moveUpButton.isEnabled = hasSelection && (selectedRows.first ?? 0) > 0
        moveDownButton.isEnabled = hasSelection && (selectedRows.last ?? 0) < store.items.count - 1
    }

    private var selectedFeed: Feed? {
        guard selectedItemIDs.count == 1, let selectedItemID = selectedItemIDs.first else { return nil }
        return store.feeds.first { $0.id == selectedItemID }
    }

    private func syncSelectionFromTable() {
        selectedItemIDs = tableView.selectedRowIndexes
            .filter { store.items.indices.contains($0) }
            .map { store.items[$0].id }
        reloadSelection()
    }

    @objc private func addFeed() {
        store.addFeed(url: URL(string: "https://example.com/feed.xml")!)
        selectedItemIDs = store.items.last.map { [$0.id] } ?? []
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: max(0, store.items.count - 1)), byExtendingSelection: false)
        reloadSelection()
        selectPane(identifier: TabID.feeds)
        editSelectedFeedColumn("url")
    }

    @objc private func addSeparator() {
        store.addSeparator()
        selectedItemIDs = store.items.last.map { [$0.id] } ?? []
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: max(0, store.items.count - 1)), byExtendingSelection: false)
        reloadSelection()
        selectPane(identifier: TabID.feeds)
        editSelectedFeedColumn("name")
    }

    @objc private func removeSelectedItem() {
        let selectedRows = tableView.selectedRowIndexes.filter { store.items.indices.contains($0) }
        guard !selectedRows.isEmpty else { return }

        let firstRemovedRow = selectedRows.first ?? 0
        let removedIDs = Set(selectedRows.map { store.items[$0].id })
        let nextSelectionIndex = min(firstRemovedRow, store.items.count - selectedRows.count - 1)
        store.removeItems(ids: removedIDs)
        selectedItemIDs = store.items.indices.contains(nextSelectionIndex) ? [store.items[nextSelectionIndex].id] : []
        tableView.reloadData()
        reloadSelection()
    }

    @objc private func moveFeedUp() {
        let selectedRows = tableView.selectedRowIndexes.filter { store.items.indices.contains($0) }
        guard let firstSelectedRow = selectedRows.first, firstSelectedRow > 0 else { return }
        selectedItemIDs = selectedRows.map { store.items[$0].id }
        guard let insertionIndex = store.moveItems(at: IndexSet(selectedRows), to: firstSelectedRow - 1) else { return }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integersIn: insertionIndex..<(insertionIndex + selectedRows.count)), byExtendingSelection: false)
    }

    @objc private func moveFeedDown() {
        let selectedRows = tableView.selectedRowIndexes.filter { store.items.indices.contains($0) }
        guard let lastSelectedRow = selectedRows.last, lastSelectedRow < store.items.count - 1 else { return }
        selectedItemIDs = selectedRows.map { store.items[$0].id }
        guard let insertionIndex = store.moveItems(at: IndexSet(selectedRows), to: lastSelectedRow + 2) else { return }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integersIn: insertionIndex..<(insertionIndex + selectedRows.count)), byExtendingSelection: false)
    }

    @objc private func applyGeneralSettingsFromControl() {
        let globalMinutes = refreshMinutes(from: globalRefreshField.stringValue) ?? store.globalRefreshMinutes
        let launchAtLogin = launchAtLoginButton.state == .on
        guard updateLaunchAtLogin(enabled: launchAtLogin) else { return }

        store.updateGeneral(
            globalRefreshMinutes: globalMinutes,
            launchAtLogin: launchAtLogin,
            notificationsEnabled: notificationsButton.state == .on,
            highlightUnreadInStatusItem: statusHighlightButton.state == .on,
            showMenuBarIcon: showMenuBarIconButton.state == .on,
            showUnreadCountInMenuBar: showMenuBarUnreadCountButton.state == .on,
            showUnreadCountInFeeds: showFeedUnreadCountButton.state == .on,
            showGlobalUpdateAll: globalUpdateAllButton.state == .on,
            showGlobalMarkAllRead: globalMarkAllReadButton.state == .on,
            showGlobalMarkAllUnread: globalMarkAllUnreadButton.state == .on,
            showGlobalShowAllUnread: globalShowAllUnreadButton.state == .on
        )
    }

    @objc private func resetIconCache() {
        iconCache.reset()
        tableView.reloadData()
    }

    @objc private func selectSettingsPane(_ sender: NSToolbarItem) {
        selectPane(identifier: sender.itemIdentifier.rawValue)
    }

    private func selectPane(identifier: String) {
        tabView.selectTabViewItem(withIdentifier: identifier)
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
    }

    private func editSelectedFeedColumn(_ identifier: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let row = self.tableView.selectedRow
            let column = self.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
            guard row >= 0, column >= 0 else { return }
            self.tableView.editColumn(column, row: row, with: nil, select: true)
        }
    }

    @objc private func editClickedFeedCell() {
        let row = tableView.clickedRow
        let column = tableView.clickedColumn
        guard canEditCell(row: row, column: column) else { return }
        tableView.editColumn(column, row: row, with: nil, select: true)
    }

    private func handleCellMouseDown(field: NSTextField, event: NSEvent) -> Bool {
        guard field.currentEditor() == nil else { return false }

        let row = tableView.row(for: field)
        let column = tableView.column(for: field)
        guard store.items.indices.contains(row), column >= 0 else { return false }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.contains(.command) {
            var selectedRows = tableView.selectedRowIndexes
            if selectedRows.contains(row) {
                selectedRows.remove(row)
            } else {
                selectedRows.insert(row)
            }
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            syncSelectionFromTable()
            return true
        }

        if modifierFlags.contains(.shift) {
            let anchorRow = tableView.selectedRow >= 0 ? tableView.selectedRow : row
            let rangeStart = min(anchorRow, row)
            let rangeEnd = max(anchorRow, row)
            let range = rangeStart..<(rangeEnd + 1)
            tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
            syncSelectionFromTable()
            return true
        }

        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            syncSelectionFromTable()
            return true
        }

        if tableView.selectedRowIndexes.count > 1 {
            tableView.mouseDown(with: event)
            syncSelectionFromTable()
            return true
        }

        if canEditCell(row: row, column: column) {
            tableView.editColumn(column, row: row, with: event, select: false)
            return true
        }

        return true
    }

    private func canEditCell(row: Int, column: Int) -> Bool {
        guard store.items.indices.contains(row), tableView.tableColumns.indices.contains(column) else { return false }
        let identifier = tableView.tableColumns[column].identifier.rawValue
        switch store.items[row] {
        case .feed:
            return identifier == "name" || identifier == "url" || identifier == "refresh"
        case .separator:
            return identifier == "name"
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) -> Bool {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            presentError(error)
            reloadGeneralSettings()
            return false
        }
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        store.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.items.indices.contains(row), let tableColumn else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FeedCell-\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let isNameColumn = tableColumn.identifier.rawValue == "name"
        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = SelectThenEditTextField(string: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isBordered = false
            label.drawsBackground = false
            label.isEditable = true
            label.isSelectable = true
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.cell?.isScrollable = true
            label.delegate = self
            cell.addSubview(label)
            cell.textField = label

            if isNameColumn {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(imageView)
                cell.imageView = imageView

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
        }

        if let label = label as? SelectThenEditTextField {
            label.mouseDownHandler = { [weak self] field, event in
                self?.handleCellMouseDown(field: field, event: event) ?? false
            }
        }

        if !isNameColumn {
            cell.imageView?.image = nil
            cell.imageView?.isHidden = true
        } else {
            cell.imageView?.isHidden = false
        }

        let item = store.items[row]
        label.textColor = .labelColor
        label.isEditable = true
        label.isSelectable = true

        if case .separator(let separator) = item {
            cell.imageView?.image = nil
            switch tableColumn.identifier.rawValue {
            case "name":
                label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                label.alignment = .left
                label.lineBreakMode = .byTruncatingTail
                label.placeholderString = "Separator"
                label.stringValue = separator.title
                label.isEditable = true
                label.isSelectable = true
            case "url":
                label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                label.alignment = .left
                label.lineBreakMode = .byTruncatingTail
                label.textColor = .tertiaryLabelColor
                label.placeholderString = nil
                label.stringValue = "Menu separator"
                label.isEditable = false
                label.isSelectable = false
            case "refresh":
                label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                label.alignment = .right
                label.lineBreakMode = .byTruncatingTail
                label.textColor = .tertiaryLabelColor
                label.placeholderString = nil
                label.stringValue = ""
                label.isEditable = false
                label.isSelectable = false
            default:
                label.placeholderString = nil
                label.stringValue = ""
            }
            return cell
        }

        guard case .feed(let feed) = item else { return cell }
        switch tableColumn.identifier.rawValue {
        case "name":
            if let image = iconCache.image(for: feed) {
                image.size = NSSize(width: 16, height: 16)
                cell.imageView?.image = image
            } else {
                cell.imageView?.image = NSImage(named: "MenuIconRead")
            }
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            label.placeholderString = feed.displayName
            label.stringValue = feed.name
        case "url":
            label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            label.alignment = .left
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = .secondaryLabelColor
            label.placeholderString = nil
            label.stringValue = feed.url.absoluteString
        case "refresh":
            label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.alignment = .right
            label.lineBreakMode = .byTruncatingTail
            label.placeholderString = globalRefreshPlaceholder()
            label.stringValue = feed.refreshMinutes.map(refreshDisplayValue) ?? ""
        default:
            label.placeholderString = nil
            label.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncSelectionFromTable()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard store.items.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(store.items[row].id.uuidString, forType: feedRowPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let draggedIDs = info.draggingPasteboard.pasteboardItems?
            .compactMap { item -> UUID? in
                guard let idString = item.string(forType: feedRowPasteboardType) else { return nil }
                return UUID(uuidString: idString)
            } ?? []
        guard !draggedIDs.isEmpty else { return false }

        let sourceIndexes = draggedIDs.compactMap { draggedID in
            store.items.firstIndex { $0.id == draggedID }
        }
        guard !sourceIndexes.isEmpty else { return false }

        let clampedRow = min(max(row, 0), store.items.count)
        let draggedItemIDs = sourceIndexes.sorted().map { store.items[$0].id }
        guard let insertionIndex = store.moveItems(at: IndexSet(sourceIndexes), to: clampedRow) else { return false }

        selectedItemIDs = draggedItemIDs
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integersIn: insertionIndex..<(insertionIndex + draggedItemIDs.count)), byExtendingSelection: false)
        reloadSelection()
        return true
    }
}

extension PreferencesWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.feeds, ToolbarID.general, .flexibleSpace, ToolbarID.about]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.feeds, ToolbarID.general, .flexibleSpace, ToolbarID.about]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.feeds, ToolbarID.general, ToolbarID.about]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(selectSettingsPane(_:))

        switch itemIdentifier {
        case ToolbarID.feeds:
            item.label = "Feeds"
            item.paletteLabel = "Feeds"
            item.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "Feeds")
                ?? NSImage(named: "MenuIconUnread")
        case ToolbarID.general:
            item.label = "General"
            item.paletteLabel = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case ToolbarID.about:
            item.label = "About"
            item.paletteLabel = "About"
            item.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "About")
        default:
            return nil
        }

        return item
    }
}

extension PreferencesWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }

        if field === globalRefreshField {
            applyGeneralSettingsFromControl()
            return
        }

        let row = tableView.row(for: field)
        let column = tableView.column(for: field)
        guard store.items.indices.contains(row), column >= 0 else { return }

        let identifier = tableView.tableColumns[column].identifier.rawValue
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if case .separator(var separator) = store.items[row] {
            guard identifier == "name" else {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
                return
            }
            separator.title = value == separator.displayName ? "" : value
            selectedItemIDs = [separator.id]
            store.updateSeparator(separator)
            tableView.reloadData()
            return
        }

        guard case .feed(var feed) = store.items[row] else { return }

        switch identifier {
        case "name":
            feed.name = value == feed.displayName ? "" : value
        case "url":
            guard let url = URL(string: value), !value.isEmpty else {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
                return
            }
            feed.url = url
        case "refresh":
            if value.isEmpty {
                feed.refreshMinutes = nil
            } else if let minutes = refreshMinutes(from: value) {
                feed.refreshMinutes = minutes
            } else {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
                return
            }
        default:
            return
        }

        selectedItemIDs = [feed.id]
        store.updateFeed(feed)
        tableView.reloadData()
    }
}

private func refreshDisplayValue(_ minutes: Int) -> String {
    minutes == 0 ? "Off" : "\(minutes)"
}

private func refreshMinutes(from value: String) -> Int? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if trimmed.caseInsensitiveCompare("off") == .orderedSame { return 0 }
    guard let minutes = Int(trimmed) else { return nil }
    return minutes >= 0 ? minutes : nil
}

private final class SelectThenEditTextField: NSTextField {
    var mouseDownHandler: ((NSTextField, NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if mouseDownHandler?(self, event) == true {
            return
        }
        super.mouseDown(with: event)
    }
}
