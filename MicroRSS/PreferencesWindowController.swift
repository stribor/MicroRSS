import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let store: FeedStore
    private let tableView = NSTableView()
    private let globalRefreshField = NSTextField()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let refreshField = NSTextField()
    private var selectedFeedID: UUID?
    private var storeObserverID: UUID?

    init(store: FeedStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MicroRSS Settings"
        super.init(window: window)
        buildUI()
        reloadSelection()
        storeObserverID = store.observe { [weak self] in
            self?.tableView.reloadData()
            self?.reloadSelection()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)

        let left = NSView()
        let right = NSView()
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)

        buildFeedList(in: left)
        buildEditor(in: right)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        split.setPosition(260, ofDividerAt: 0)
    }

    private func buildFeedList(in container: NSView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feed")))
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(selectionChanged)
        scroll.documentView = tableView

        let addButton = NSButton(title: "+", target: self, action: #selector(addFeed))
        let removeButton = NSButton(title: "-", target: self, action: #selector(removeFeed))
        let upButton = NSButton(title: "Up", target: self, action: #selector(moveFeedUp))
        let downButton = NSButton(title: "Down", target: self, action: #selector(moveFeedDown))
        let controls = NSStackView(views: [addButton, removeButton, upButton, downButton])
        controls.orientation = NSUserInterfaceLayoutOrientation.horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
    }

    private func buildEditor(in container: NSView) {
        let form = NSGridView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 12
        form.columnSpacing = 12

        globalRefreshField.stringValue = "\(store.globalRefreshMinutes)"
        nameField.placeholderString = "Use feed title"
        urlField.placeholderString = "https://example.com/feed.xml"
        refreshField.placeholderString = "Use global"

        form.addRow(with: [label("Global refresh (min)"), globalRefreshField])
        form.addRow(with: [label("Feed name"), nameField])
        form.addRow(with: [label("Feed URL"), urlField])
        form.addRow(with: [label("Refresh override (min)"), refreshField])

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded

        container.addSubview(form)
        container.addSubview(saveButton)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            saveButton.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 20)
        ])
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func reloadSelection() {
        if selectedFeedID == nil, let first = store.feeds.first {
            selectedFeedID = first.id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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

    @objc private func save() {
        store.updateGlobalRefresh(minutes: Int(globalRefreshField.stringValue) ?? store.globalRefreshMinutes)
        guard var feed = selectedFeed, let url = URL(string: urlField.stringValue) else { return }
        feed.name = nameField.stringValue
        feed.url = url
        let override = Int(refreshField.stringValue)
        feed.refreshMinutes = override.flatMap { $0 > 0 ? $0 : nil }
        store.updateFeed(feed)
        tableView.reloadData()
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        store.feeds.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.feeds.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FeedCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        label.stringValue = store.feeds[row].displayName
        return cell
    }
}
