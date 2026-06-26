import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let store: FeedStore
    private let tableView = NSTableView()
    private let globalRefreshField = NSTextField()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let refreshField = NSTextField()
    private let feedCountLabel = NSTextField(labelWithString: "")
    private var selectedFeedID: UUID?
    private var storeObserverID: UUID?

    init(store: FeedStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Feeds"
        window.minSize = NSSize(width: 780, height: 500)
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

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        root.addArrangedSubview(buildHeader())
        root.addArrangedSubview(buildFeedTable())
        root.addArrangedSubview(buildFeedControls())
        root.addArrangedSubview(buildEditor())
    }

    private func buildHeader() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "Feeds")
        title.font = NSFont.boldSystemFont(ofSize: 17)

        globalRefreshField.stringValue = "\(store.globalRefreshMinutes)"
        configureSingleLineField(globalRefreshField)

        let label = NSTextField(labelWithString: "Global refresh (min)")
        let stack = NSStackView(views: [label, globalRefreshField])
        stack.orientation = .horizontal
        stack.spacing = 8

        title.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            globalRefreshField.widthAnchor.constraint(equalToConstant: 72),
            container.heightAnchor.constraint(equalToConstant: 28)
        ])

        return container
    }

    private func buildFeedTable() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView.addTableColumn(column("name", title: "Name", width: 240, minWidth: 160))
        tableView.addTableColumn(column("url", title: "URL", width: 500, minWidth: 260))
        tableView.addTableColumn(column("refresh", title: "Refresh", width: 90, minWidth: 80))
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(selectionChanged)
        scroll.documentView = tableView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
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
        let form = NSGridView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 12
        form.columnSpacing = 12

        nameField.placeholderString = "Use feed title"
        urlField.placeholderString = "https://example.com/feed.xml"
        refreshField.placeholderString = "Use global"
        [nameField, urlField, refreshField].forEach(configureSingleLineField)

        form.addRow(with: [label("Feed name"), nameField])
        form.addRow(with: [label("Feed URL"), urlField])
        form.addRow(with: [label("Refresh override (min)"), refreshField])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded

        container.addSubview(form)
        container.addSubview(saveButton)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            saveButton.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 20)
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
        let globalMinutes = Int(globalRefreshField.stringValue) ?? store.globalRefreshMinutes
        let name = nameField.stringValue
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = Int(refreshField.stringValue)

        var updatedFeed = selectedFeed
        if var feed = updatedFeed, let url = URL(string: urlString), !urlString.isEmpty {
            feed.name = name
            feed.url = url
            feed.refreshMinutes = override.flatMap { $0 > 0 ? $0 : nil }
            updatedFeed = feed
        }

        store.update(globalRefreshMinutes: globalMinutes, feed: updatedFeed)
        tableView.reloadData()
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
        switch tableColumn.identifier.rawValue {
        case "name":
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            label.alignment = .left
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
            label.stringValue = feed.refreshMinutes.map { "\($0)m" } ?? "\(store.globalRefreshMinutes)m"
        default:
            label.stringValue = ""
        }
        return cell
    }
}
