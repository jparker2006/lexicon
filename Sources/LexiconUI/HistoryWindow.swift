public import AppKit
import os
public import LexiconDomain
import History
import LexiconCore

/// Opens the History window from the menu bar, or when Lexicon is reopened from
/// Spotlight or Finder. One window at a time; a second open brings it forward.
/// Closing the window drops it, its reader and the reader's SQLite connection
/// (closed, not hidden: #4), so a closed window costs no memory.
@MainActor
public final class HistoryWindowPresenter: NSObject {
    private let paths: AppPaths
    private var controller: HistoryWindowController?
    private let log = Logger(subsystem: "Lexicon", category: "History")

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// The menu bar menu's "History" line.
    public func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "History", action: #selector(show), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc public func show() {
        KeyEquivalents.install()
        NSApp.activate()
        if let controller {
            controller.showWindow(nil)
            return
        }
        let clock = ContinuousClock()
        let opened = clock.now
        let controller = HistoryWindowController(reader: HistoryReader(paths: paths), pasteboard: .general) { [weak self] in
            self?.controller = nil
        }
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.displayIfNeeded()
        // The budget is click to first rows, 100 ms or less at p95; this is the in-process part.
        let ms = (clock.now - opened) / .milliseconds(1)
        log.notice("History window: first rows drawn \(Int(ms.rounded()), privacy: .public) ms after open")
    }
}

/// The History window: one view-based NSTableView. Day headers are group rows.
/// The table asks only for rows on screen; the data source maps a flat row
/// index to (day section, offset) and fetches pages of 50 from `HistoryReader`.
///
/// Row: time, full final text, grey line (model, lag, status for waiting /
/// recovered / not inserted / failed). Clicking a row copies the final text and
/// flashes "Copied". The search field filters with a plain-text match.
@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
    NSToolbarDelegate {
    let reader: HistoryReader
    let pasteboard: NSPasteboard
    let onClose: @MainActor () -> Void
    let table = HistoryTable()
    let search = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
    let empty = NSTextField(labelWithString: "")
    /// The days on the table, newest first: a screenful at open, more as Jake scrolls.
    var sections: [DaySection] = []
    /// The search the sections were read with.
    var query = ""
    /// No older day matches: scrolling to the end asks for nothing more.
    var complete = false
    /// The flat index of each section's header.
    var headers: [Int] = []
    var rowCount = 0
    var pages: [Page: [HistoryRow]] = [:]
    var version = 0
    static let pageSize = 50
    /// Rows read at a time. Reading, and handing the table, a year of rows
    /// costs more than the whole open budget, so the window starts with the
    /// newest days and grows as Jake scrolls toward the end.
    static let batch = 300

    struct Page: Hashable {
        let section: Int
        let index: Int
    }

    enum Item {
        case header(Int)
        case row(section: Int, offset: Int)
    }

    init(reader: HistoryReader, pasteboard: NSPasteboard, onClose: @escaping @MainActor () -> Void) {
        self.reader = reader
        self.pasteboard = pasteboard
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init(window: window)
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 300)
        window.setAccessibilityIdentifier(AccessibilityID.historyWindow)
        window.delegate = self
        if !window.setFrameUsingName("History") { window.center() }
        window.setFrameAutosaveName("History")

        let toolbar = NSToolbar(identifier: "History")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        search.searchField.placeholderString = "Search"
        search.searchField.target = self
        search.searchField.action = #selector(searched(_:))
        search.searchField.setAccessibilityIdentifier(AccessibilityID.historySearch)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dictation"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.floatsGroupRows = true
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityIdentifier(AccessibilityID.historyTable)
        table.target = self
        table.action = #selector(clicked(_:))
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        scroll.frame = content.bounds
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        content.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func reload() {
        // Version first: a commit landing between the two reads then costs one extra reload, never a missed one.
        version = reader.version
        query = search.searchField.stringValue
        sections = []
        headers = []
        rowCount = 0
        pages = [:]
        complete = false
        _ = showMore()
        empty.stringValue = query.isEmpty ? "No Dictations yet" : "No matches"
        empty.isHidden = !sections.isEmpty
        table.reloadData()
    }

    /// Reads the next `batch` rows' worth of whole days. false: nothing older matches.
    func showMore() -> Bool {
        guard !complete else { return false }
        let more = reader.sections(matching: query, after: sections.last, rows: Self.batch)
        complete = more.reduce(0) { $0 + $1.count } < Self.batch
        for section in more {
            headers.append(rowCount)
            rowCount += 1 + section.count
        }
        sections += more
        return !more.isEmpty
    }

    @objc func scrolled(_ notification: Notification) {
        guard table.rows(in: table.visibleRect).upperBound > rowCount - Self.batch / 2, showMore() else { return }
        table.noteNumberOfRowsChanged()
    }

    @objc func searched(_ sender: NSSearchField) {
        reload()
        table.scrollRowToVisible(0)
    }

    /// Clicking a row copies its final text to the clipboard and flashes "Copied" on it.
    @objc func clicked(_ sender: Any?) {
        copy(row: table.clickedRow)
    }

    func copy(row: Int) {
        guard let text = historyRow(at: row)?.finalText else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowCell)?.flashCopied()
    }

    /// Binary search over the headers: the table asks for every row it lays out.
    func item(at row: Int) -> Item? {
        guard row >= 0, row < rowCount else { return nil }
        var low = 0, high = headers.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if headers[middle] <= row { low = middle } else { high = middle }
        }
        let section = low
        let offset = row - headers[section] - 1
        return offset < 0 ? .header(section) : .row(section: section, offset: offset)
    }

    func historyRow(at row: Int) -> HistoryRow? {
        guard case .row(let section, let offset) = item(at: row) else { return nil }
        let page = Page(section: section, index: offset / Self.pageSize)
        let start = page.index * Self.pageSize
        let rows = pages[page] ?? reader.rows(in: sections[section], offsets: start..<min(start + Self.pageSize, sections[section].count))
        // A short page (a read error) is fetched again next time rather than kept.
        if start + rows.count == min(start + Self.pageSize, sections[section].count) { pages[page] = rows }
        let index = offset % Self.pageSize
        return index < rows.count ? rows[index] : nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = item(at: row) { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch item(at: row) {
        case .header(let section):
            let cell = tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell ?? HeaderCell()
            cell.label.stringValue = HistoryText.title(for: sections[section].day)
            return cell
        case .row:
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(historyRow(at: row))
            return cell
        case nil:
            return nil
        }
    }

    // MARK: Window

    /// Back from another app: show what was dictated meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        if reader.version != version { reload() }
    }

    /// Closing drops the controller, the reader and its connection.
    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, search.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == search.itemIdentifier ? search : nil
    }
}

/// A click on a row copies it even when the window is in the background: without
/// this, AppKit spends that first click bringing the window forward and the row
/// is not copied.
final class HistoryTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A day header: a floating group row.
final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("day")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }
}

/// One Dictation: time on the left, the full final text wrapped (never cut
/// off), the grey line under it.
final class RowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("row")
    let time = NSTextField(labelWithString: "")
    let copied = NSTextField(labelWithString: "Copied")
    let text = NSTextField(wrappingLabelWithString: "")
    let details = NSTextField(labelWithString: "")
    /// Which flash may hide "Copied": a newer click keeps it up.
    private var flashes = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        time.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        time.textColor = .secondaryLabelColor
        copied.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        copied.textColor = .controlAccentColor
        copied.isHidden = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Selectable text would take the click, and a click on a row copies it.
        text.isSelectable = false
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.textColor = .tertiaryLabelColor
        details.lineBreakMode = .byTruncatingTail
        for view in [time, copied, text, details] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            time.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            time.widthAnchor.constraint(equalToConstant: 64),
            copied.leadingAnchor.constraint(equalTo: time.leadingAnchor),
            copied.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 2),
            text.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            details.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            details.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            details.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(_ row: HistoryRow?) {
        flashes += 1
        copied.isHidden = true
        time.stringValue = row?.startedAt.formatted(date: .omitted, time: .shortened) ?? ""
        text.stringValue = row?.finalText ?? ""
        text.placeholderString = row?.finalText == nil ? "No text" : nil
        details.stringValue = row.map(HistoryText.details) ?? ""
    }

    func flashCopied() {
        flashes += 1
        let flash = flashes
        copied.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, flashes == flash else { return }
            copied.isHidden = true
        }
    }
}

/// Settings: Private mode, cloud model, local model (install / remove), mic,
/// API keys (Keychain), start at login. NSGridView of plain controls. Layout is fog.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: PreferencesStore, secrets: Secrets) { fatalError("not implemented") }
    required init?(coder: NSCoder) { fatalError("not implemented") }
}
