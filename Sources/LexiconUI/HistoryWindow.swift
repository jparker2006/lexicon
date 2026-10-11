import AppKit
import os
public import LexiconDomain
import History
import LexiconCore

/// Opens the History window from the menu bar, or when Lexicon is reopened from
/// Spotlight or Finder. One window at a time; a second open brings it forward.
/// Closing the window drops it, its reader and the reader's SQLite connection
/// (closed, not hidden: #4), so a closed window costs no memory.
@MainActor
public final class HistoryWindowPresenter {
    private let paths: AppPaths
    private var controller: HistoryWindowController?
    private let log = Logger(subsystem: "Lexicon", category: "History")

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func show() {
        // An accessory app shows no menu bar, but key equivalents (Cmd-W, Cmd-V in
        // the search field) still route through the main menu.
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.keyEquivalents() }
        NSApp.activate()
        if let controller {
            controller.showWindow(nil)
            return
        }
        let clock = ContinuousClock()
        let opened = clock.now
        let reader: HistoryReader?
        do {
            reader = try HistoryReader(paths: paths)
        } catch {
            log.error("History window opened without its reader: \(String(describing: error), privacy: .private)")
            reader = nil
        }
        let controller = HistoryWindowController(reader: reader, pasteboard: .general) { [weak self] in self?.controller = nil }
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.displayIfNeeded()
        // The budget is click to first rows, 100 ms or less at p95; this is the in-process part.
        let ms = (clock.now - opened) / .milliseconds(1)
        log.notice("History window: first rows drawn \(Int(ms.rounded()), privacy: .public) ms after open")
    }

    private static func keyEquivalents() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let menu = NSMenu()
        for submenu in [edit, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
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
    /// nil when History could not be opened: the window shows it as empty.
    let reader: HistoryReader?
    let pasteboard: NSPasteboard
    let onClose: @MainActor () -> Void
    let table = NSTableView()
    let search = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
    let empty = NSTextField(labelWithString: "")
    var sections: [DaySection] = []
    /// The flat index of each section's header.
    var headers: [Int] = []
    var pages: [Page: [HistoryRow]] = [:]
    var version = 0
    static let pageSize = 50

    struct Page: Hashable {
        let section: Int
        let index: Int
    }

    enum Item {
        case header(Int)
        case row(section: Int, offset: Int)
    }

    init(reader: HistoryReader?, pasteboard: NSPasteboard, onClose: @escaping @MainActor () -> Void) {
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
        sections = reader?.sections(matching: search.searchField.stringValue) ?? []
        version = reader?.version ?? 0
        pages = [:]
        var next = 0
        headers = sections.map { section in
            defer { next += 1 + section.count }
            return next
        }
        empty.stringValue = search.searchField.stringValue.isEmpty ? "No Dictations yet" : "No matches"
        empty.isHidden = !sections.isEmpty
        table.reloadData()
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

    func item(at row: Int) -> Item? {
        guard row >= 0, let section = headers.lastIndex(where: { $0 <= row }) else { return nil }
        let offset = row - headers[section] - 1
        guard offset < sections[section].count else { return nil }
        return offset < 0 ? .header(section) : .row(section: section, offset: offset)
    }

    func historyRow(at row: Int) -> HistoryRow? {
        guard case .row(let section, let offset) = item(at: row), let reader else { return nil }
        let page = Page(section: section, index: offset / Self.pageSize)
        if pages[page] == nil {
            let start = page.index * Self.pageSize
            pages[page] = reader.rows(in: sections[section], offsets: start..<min(start + Self.pageSize, sections[section].count))
        }
        let rows = pages[page] ?? []
        let index = offset % Self.pageSize
        return index < rows.count ? rows[index] : nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        sections.reduce(sections.count) { $0 + $1.count }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = item(at: row) { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch item(at: row) {
        case .header(let section):
            let cell = tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell ?? HeaderCell()
            cell.label.stringValue = Self.title(for: sections[section].day)
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
        if reader?.version != version { reload() }
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

    // MARK: Text

    /// "Today", "Yesterday", "Friday, October 9", and the year once it is not this year's.
    static func title(for day: DateComponents, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = calendar.date(from: day) else { return "" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// The grey line: model, lag, then any status or Cleanup outcome worth a word.
    static func details(_ row: HistoryRow) -> String {
        [
            row.model?.displayName,
            row.lag.map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" },
            label(for: row.status),
            row.cleanup.flatMap(label(for:)),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Status text is an exhaustive switch: a new DictationStatus fails the build here.
    static func label(for status: DictationStatus) -> String? {
        switch status {
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .waiting: "waiting"
        case .inserted: nil
        case .ready: "pasting"
        case .notInserted: "not inserted"
        case .recovered: "recovered"
        case .failed: "failed"
        }
    }

    /// Cleanup's part of the grey line. Exhaustive: a new reason fails the build here.
    static func label(for cleanup: CleanupOutcome) -> String? {
        switch cleanup {
        case .aiAccepted: nil
        case .rulesOnly(.off): nil
        case .rulesOnly(.rejected): "cleanup rejected"
        case .rulesOnly(.deadline): "cleanup late"
        case .rulesOnly(.unavailable): "cleanup unavailable"
        }
    }
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
        details.stringValue = row.map(HistoryWindowController.details) ?? ""
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

/// What the History window may ask for. Closures over the system, so the window
/// never holds the Conductor or the store directly.
struct HistoryCommands {
    let retry: @MainActor (DictationID, SpeechModel?) -> Void
    let setPinned: @MainActor (DictationID, Bool) -> Void
    let delete: @MainActor (DictationID) -> Void
}

/// Settings: Private mode, cloud model, local model (install / remove), mic,
/// API keys (Keychain), start at login. NSGridView of plain controls. Layout is fog.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: PreferencesStore, secrets: Secrets) { fatalError("not implemented") }
    required init?(coder: NSCoder) { fatalError("not implemented") }
}
