import AppKit
import ServiceManagement

@MainActor
final class PreferencesWindowController: NSWindowController {
    private enum TabID {
        static let general = "general"
        static let feeds = "feeds"
    }

    private let store: FeedStore
    private let tabView = NSTabView()
    private let tableView = NSTableView()
    private let globalRefreshField = NSTextField()
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let notificationsButton = NSButton(checkboxWithTitle: "Show notifications for new articles", target: nil, action: nil)
    private let statusHighlightButton = NSButton(checkboxWithTitle: "Highlight unread items in the menu bar", target: nil, action: nil)
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let refreshField = NSTextField()
    private let feedCountLabel = NSTextField(labelWithString: "")
    private var selectedFeedID: UUID?
    private var storeObserverID: UUID?

    init(store: FeedStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MicroRSS Settings"
        window.minSize = NSSize(width: 820, height: 520)
        super.init(window: window)
        buildUI()
        reloadGeneralSettings()
        reloadSelection()
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

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        tabView.addTabViewItem(tabItem(identifier: TabID.general, label: "General", view: buildGeneralPane()))
        tabView.addTabViewItem(tabItem(identifier: TabID.feeds, label: "Feeds", view: buildFeedsPane()))
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

        let title = NSTextField(labelWithString: "General")
        title.font = NSFont.boldSystemFont(ofSize: 17)

        globalRefreshField.placeholderString = "30"
        configureSingleLineField(globalRefreshField)

        let form = NSGridView()
        form.rowSpacing = 12
        form.columnSpacing = 12
        form.addRow(with: [label("Global refresh (min)"), globalRefreshField])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .leading

        let options = NSStackView(views: [launchAtLoginButton, notificationsButton, statusHighlightButton])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 10

        let saveButton = NSButton(title: "Save General Settings", target: self, action: #selector(saveGeneralSettings))
        saveButton.bezelStyle = .rounded

        root.addArrangedSubview(title)
        root.addArrangedSubview(form)
        root.addArrangedSubview(options)
        root.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -28),
            globalRefreshField.widthAnchor.constraint(equalToConstant: 72)
        ])

        return container
    }

    private func buildFeedsPane() -> NSView {
        let container = NSView()
        let root = NSStackView()
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let listPane = NSStackView()
        listPane.orientation = .vertical
        listPane.spacing = 10
        listPane.addArrangedSubview(buildFeedHeader())
        listPane.addArrangedSubview(buildFeedTable())
        listPane.addArrangedSubview(buildFeedControls())
        listPane.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let editorPane = buildEditor()
        editorPane.setContentHuggingPriority(.required, for: .horizontal)

        root.addArrangedSubview(listPane)
        root.addArrangedSubview(editorPane)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            editorPane.widthAnchor.constraint(equalToConstant: 320)
        ])

        return container
    }

    private func buildFeedHeader() -> NSView {
        let title = NSTextField(labelWithString: "Feeds")
        title.font = NSFont.boldSystemFont(ofSize: 17)
        return title
    }

    private func buildFeedTable() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView.addTableColumn(column("name", title: "Name", width: 220, minWidth: 160))
        tableView.addTableColumn(column("url", title: "URL", width: 360, minWidth: 240))
        tableView.addTableColumn(column("refresh", title: "Refresh", width: 80, minWidth: 72))
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(selectionChanged)
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
        let removeButton = NSButton(title: "-", target: self, action: #selector(removeFeed))
        let upButton = NSButton(title: "Up", target: self, action: #selector(moveFeedUp))
        let downButton = NSButton(title: "Down", target: self, action: #selector(moveFeedDown))
        let spacer = NSView()

        feedCountLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        feedCountLabel.alignment = .center

        let controls = NSStackView(views: [addButton, removeButton, upButton, downButton, spacer, feedCountLabel])
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

    private func buildEditor() -> NSView {
        let container = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let title = NSTextField(labelWithString: "Selected Feed")
        title.font = NSFont.boldSystemFont(ofSize: 15)

        nameField.placeholderString = "Use feed title"
        urlField.placeholderString = "https://example.com/feed.xml"
        refreshField.placeholderString = "Use global"
        [nameField, urlField, refreshField].forEach(configureSingleLineField)

        let form = NSGridView()
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.addRow(with: [label("Name"), nameField])
        form.addRow(with: [label("URL"), urlField])
        form.addRow(with: [label("Refresh (min)"), refreshField])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        let saveButton = NSButton(title: "Save Feed", target: self, action: #selector(saveFeed))
        saveButton.bezelStyle = .rounded

        root.addArrangedSubview(title)
        root.addArrangedSubview(form)
        root.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            refreshField.widthAnchor.constraint(equalToConstant: 96)
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

    private func reloadGeneralSettings() {
        globalRefreshField.stringValue = "\(store.globalRefreshMinutes)"
        launchAtLoginButton.state = store.launchAtLogin ? .on : .off
        notificationsButton.state = store.notificationsEnabled ? .on : .off
        statusHighlightButton.state = store.highlightUnreadInStatusItem ? .on : .off
    }

    private func reloadSelection() {
        feedCountLabel.stringValue = "\(store.feeds.count) \(store.feeds.count == 1 ? "feed" : "feeds")"

        if selectedFeedID == nil, let first = store.feeds.first {
            selectedFeedID = first.id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else if let selectedFeedID,
                  let row = store.feeds.firstIndex(where: { $0.id == selectedFeedID }),
                  tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        guard let feed = selectedFeed else {
            nameField.stringValue = ""
            urlField.stringValue = ""
            refreshField.stringValue = ""
            return
        }

        nameField.stringValue = feed.name
        urlField.stringValue = feed.url.absoluteString
        refreshField.stringValue = feed.refreshMinutes.map(String.init) ?? ""
    }

    private var selectedFeed: Feed? {
        guard let selectedFeedID else { return nil }
        return store.feeds.first { $0.id == selectedFeedID }
    }

    @objc private func selectionChanged() {
        let row = tableView.selectedRow
        guard store.feeds.indices.contains(row) else { return }
        selectedFeedID = store.feeds[row].id
        reloadSelection()
    }

    @objc private func addFeed() {
        store.addFeed(url: URL(string: "https://example.com/feed.xml")!)
        selectedFeedID = store.feeds.last?.id
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: max(0, store.feeds.count - 1)), byExtendingSelection: false)
        reloadSelection()
        tabView.selectTabViewItem(withIdentifier: TabID.feeds)
        focusURLField()
    }

    @objc private func removeFeed() {
        guard let selectedFeedID else { return }
        store.removeFeed(id: selectedFeedID)
        self.selectedFeedID = store.feeds.first?.id
        tableView.reloadData()
        reloadSelection()
    }

    @objc private func moveFeedUp() {
        let row = tableView.selectedRow
        guard row > 0 else { return }
        store.moveFeed(from: row, to: row - 1)
        tableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveFeedDown() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.feeds.count - 1 else { return }
        store.moveFeed(from: row, to: row + 1)
        tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func saveGeneralSettings() {
        let globalMinutes = Int(globalRefreshField.stringValue) ?? store.globalRefreshMinutes
        let launchAtLogin = launchAtLoginButton.state == .on
        guard updateLaunchAtLogin(enabled: launchAtLogin) else { return }

        store.updateGeneral(
            globalRefreshMinutes: globalMinutes,
            launchAtLogin: launchAtLogin,
            notificationsEnabled: notificationsButton.state == .on,
            highlightUnreadInStatusItem: statusHighlightButton.state == .on
        )
    }

    @objc private func saveFeed() {
        let name = nameField.stringValue
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = Int(refreshField.stringValue)

        guard var feed = selectedFeed, let url = URL(string: urlString), !urlString.isEmpty else { return }
        feed.name = name
        feed.url = url
        feed.refreshMinutes = override.flatMap { $0 > 0 ? $0 : nil }

        store.updateFeed(feed)
        tableView.reloadData()
    }

    private func focusURLField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.urlField)
            self.urlField.currentEditor()?.selectAll(nil)
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
        store.feeds.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.feeds.indices.contains(row), let tableColumn else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FeedCell-\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let feed = store.feeds[row]
        label.textColor = .labelColor
        switch tableColumn.identifier.rawValue {
        case "name":
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            label.stringValue = feed.displayName
        case "url":
            label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            label.alignment = .left
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = .secondaryLabelColor
            label.stringValue = feed.url.absoluteString
        case "refresh":
            label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.alignment = .right
            label.lineBreakMode = .byTruncatingTail
            label.stringValue = feed.refreshMinutes.map { "\($0)m" } ?? "\(store.globalRefreshMinutes)m"
        default:
            label.stringValue = ""
        }
        return cell
    }
}
