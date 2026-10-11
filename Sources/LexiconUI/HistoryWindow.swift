public import AppKit
import AVFAudio
import os
public import LexiconDomain
import History
public import LexiconCore

/// Opens the History window from the menu bar, or when Lexicon is reopened from
/// Spotlight or Finder. One window at a time; a second open brings it forward.
/// Closing the window drops it, its reader and the reader's SQLite connection
/// (closed, not hidden: #4), so a closed window costs no memory.
@MainActor
public final class HistoryWindowPresenter: NSObject {
    private let paths: AppPaths
    /// Pin, Retry and Delete go through it. nil when it did not open: History stays readable.
    private let system: LexiconSystem?
    private var controller: HistoryWindowController?
    /// Dictations being retried. Kept here, not in the window, so History closed and
    /// reopened mid-Retry still says "Retrying…" and still refuses a second Retry.
    private(set) var retrying: Set<DictationID> = []
    private let log = Logger(subsystem: "Lexicon", category: "History")

    public init(paths: AppPaths, system: LexiconSystem?) {
        self.paths = paths
        self.system = system
    }

    /// The menu bar menu's "History" line.
    public func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "History", action: #selector(show), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc public func show() {
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
        let controller = HistoryWindowController(reader: HistoryReader(paths: paths), system: system,
                                                  pasteboard: .general) { [weak self] in
            self?.controller = nil
        }
        controller.presenter = self
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.displayIfNeeded()
        // The budget is click to first rows, 100 ms or less at p95; this is the in-process part.
        let ms = (clock.now - opened) / .milliseconds(1)
        log.notice("History window: first rows drawn \(Int(ms.rounded()), privacy: .public) ms after open")
    }

    /// Never typed: the new text replaces the old in History, and a failed Dictation becomes not inserted.
    func retry(_ id: DictationID, with model: SpeechModel) {
        guard let system, retrying.insert(id).inserted else { return }
        controller?.redrawRows()
        Task {
            let result = await system.conductor.retry(id, with: model)
            await system.history.flush()
            retrying.remove(id)
            controller?.refresh()
            controller?.cell(for: id)?.flash(result.versions == nil ? "No text" : "Retried")
        }
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
/// recovered / not inserted / failed), then play, the Test set pin and a ⋯ menu
/// (Retry with a model picker, Show Versions, Delete). Clicking a row copies the
/// final text and flashes "Copied". The search field filters with a plain-text match.
@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
    NSToolbarDelegate {
    let reader: HistoryReader
    let system: LexiconSystem?
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
    /// The one clip playing, and whose it is.
    var player: AVAudioPlayer?
    var playing: DictationID?
    /// Holds the Retries in progress. Set right after init.
    weak var presenter: HistoryWindowPresenter?
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

    init(reader: HistoryReader, system: LexiconSystem?, pasteboard: NSPasteboard,
         onClose: @escaping @MainActor () -> Void) {
        self.reader = reader
        self.system = system
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

    /// After Jake's own change: read again, keeping the rows he has scrolled to and his place in them.
    func refresh() {
        let shown = rowCount
        let clip = table.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        reload()
        if rowCount < shown {
            while rowCount < shown, showMore() {}
            table.reloadData()
        }
        if let clip, let origin {
            clip.scroll(to: origin)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
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
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowCell)?.flash("Copied")
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
            cell.owner = self
            let shown = historyRow(at: row)
            let retrying = shown.map { presenter?.retrying.contains($0.id) ?? false } ?? false
            cell.show(shown, actions: shown.map { RowActions($0, canWrite: system != nil, retrying: retrying) },
                      playing: shown != nil && shown?.id == playing, retrying: retrying)
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

    /// Closing drops the controller, the reader and its connection, and stops playing.
    func windowWillClose(_ notification: Notification) {
        stopPlaying()
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

// MARK: Row actions

extension HistoryWindowController: AVAudioPlayerDelegate {
    /// Play toggles: the same row stops it, another row's play replaces it.
    func togglePlay(_ row: HistoryRow) {
        let again = playing == row.id
        stopPlaying()
        guard !again else { return }
        // Aged out or deleted since the row was drawn.
        guard let url = reader.audioURL(row.id) else { return refresh() }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        // A file a crash left unreadable: say so rather than doing nothing.
        guard let player, player.play() else {
            cell(for: row.id)?.flash("Can't play")
            return
        }
        self.player = player
        playing = row.id
        redrawRows()
    }

    func stopPlaying() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        playing = nil
        redrawRows()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if self.player.map(ObjectIdentifier.init) == finished { self.stopPlaying() }
        }
    }

    /// The Test set pin: its audio is kept forever. History refuses a pin with no audio to keep.
    func togglePin(_ row: HistoryRow) {
        guard let system else { return }
        system.history.record(.pinned(row.id, !row.pinned))
        Task {
            await system.history.flush()
            refresh()
        }
    }

    func showMenu(for row: HistoryRow, from button: NSButton) {
        let actions = RowActions(row, canWrite: system != nil, retrying: presenter?.retrying.contains(row.id) ?? false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let models = NSMenu()
        models.autoenablesItems = false
        for (model, enabled) in RowActions.retryModels {
            let item = NSMenuItem(title: model.displayName, action: #selector(retryPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (row.id, model)
            item.isEnabled = enabled && actions.retry
            models.addItem(item)
        }
        let retry = menu.addItem(withTitle: "Retry with", action: nil, keyEquivalent: "")
        retry.submenu = models
        retry.isEnabled = actions.retry
        let versions = menu.addItem(withTitle: "Show Versions", action: #selector(versionsPicked(_:)), keyEquivalent: "")
        versions.target = self
        versions.representedObject = row
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "Delete…", action: #selector(deletePicked(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = row
        delete.isEnabled = actions.delete
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc func retryPicked(_ sender: NSMenuItem) {
        guard let (id, model) = sender.representedObject as? (DictationID, SpeechModel) else { return }
        presenter?.retry(id, with: model)
    }

    @objc func versionsPicked(_ sender: NSMenuItem) {
        guard let window, let row = sender.representedObject as? HistoryRow, let detail = reader.detail(row.id) else { return }
        let alert = NSAlert()
        alert.messageText = "Versions"
        let sections = HistoryText.versions(detail)
        if sections.isEmpty {
            alert.informativeText = "This Dictation has no text yet."
        } else {
            alert.accessoryView = VersionsView.make(sections)
        }
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window)
    }

    /// Asks first: the text and audio are gone for good.
    @objc func deletePicked(_ sender: NSMenuItem) {
        guard let window, let system, let row = sender.representedObject as? HistoryRow else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this Dictation?"
        alert.informativeText = "Its text and audio are removed from History. This can't be undone."
        // Return must not delete: Delete takes a click, and Escape (on Cancel) backs out.
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // History refuses it while the Dictation is in flight; the row then stays.
            system.history.record(.deleted(row.id))
            Task { @MainActor in
                if self?.playing == row.id { self?.stopPlaying() }
                await system.history.flush()
                self?.refresh()
            }
        }
    }

    /// Redraws the rows on screen (play state, "Retrying…") without reading History again.
    func redrawRows() {
        let visible = table.rows(in: table.visibleRect)
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.lowerBound..<visible.upperBound), columnIndexes: [0])
    }

    /// The row's view on screen. After a reload the table drops its views and makes
    /// them again at the next layout, so lay out first.
    func cell(for id: DictationID) -> RowCell? {
        table.layoutSubtreeIfNeeded()
        let visible = table.rows(in: table.visibleRect)
        guard let row = (visible.lowerBound..<visible.upperBound).first(where: { historyRow(at: $0)?.id == id }) else {
            return nil
        }
        return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? RowCell
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
/// off), the grey line under it with the row's buttons at its end.
final class RowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("row")
    let time = NSTextField(labelWithString: "")
    /// "Copied", "Retrying…", "Retried": a word under the time.
    let note = NSTextField(labelWithString: "")
    let text = NSTextField(wrappingLabelWithString: "")
    let details = NSTextField(labelWithString: "")
    let play = RowCell.button(AccessibilityID.historyPlay)
    let pin = RowCell.button(AccessibilityID.historyPin)
    let more = RowCell.button(AccessibilityID.historyMore, symbol: "ellipsis.circle", label: "More")
    weak var owner: HistoryWindowController?
    var row: HistoryRow?
    /// Which flash may hide the note: a newer one keeps it up.
    private var flashes = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        time.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        time.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        note.textColor = .controlAccentColor
        note.isHidden = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Selectable text would take the click, and a click on a row copies it.
        text.isSelectable = false
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.textColor = .tertiaryLabelColor
        details.lineBreakMode = .byTruncatingTail
        play.action = #selector(playPressed)
        pin.action = #selector(pinPressed)
        more.action = #selector(morePressed)
        let buttons = NSStackView(views: [play, pin, more])
        buttons.spacing = 6
        for button in [play, pin, more] { button.target = self }
        for view in [time, note, text, details, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            time.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            time.widthAnchor.constraint(equalToConstant: 64),
            note.leadingAnchor.constraint(equalTo: time.leadingAnchor),
            note.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 2),
            text.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            details.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            details.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 4),
            details.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.centerYAnchor.constraint(equalTo: details.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// `actions` nil (a row that did not load): every button is off.
    func show(_ row: HistoryRow?, actions: RowActions?, playing: Bool, retrying: Bool) {
        flashes += 1
        self.row = row
        note.stringValue = "Retrying…"
        note.isHidden = !retrying
        time.stringValue = row?.startedAt.formatted(date: .omitted, time: .shortened) ?? ""
        text.stringValue = row?.finalText ?? ""
        text.placeholderString = row?.finalText == nil ? "No text" : nil
        details.stringValue = row.map(HistoryText.details) ?? ""
        Self.set(play, symbol: playing ? "stop.fill" : "play.fill", label: playing ? "Stop" : "Play")
        play.isEnabled = actions?.play ?? false
        let pinned = row?.pinned ?? false
        Self.set(pin, symbol: pinned ? "flag.fill" : "flag",
                 label: pinned ? "Unpin from the Test set" : "Pin to the Test set (keeps its audio)")
        pin.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pin.isEnabled = actions?.pin ?? false
        more.isEnabled = row != nil
    }

    func flash(_ word: String) {
        flashes += 1
        let flash = flashes
        note.stringValue = word
        note.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, flashes == flash else { return }
            note.isHidden = true
        }
    }

    @objc func playPressed() {
        if let row { owner?.togglePlay(row) }
    }

    @objc func pinPressed() {
        if let row { owner?.togglePin(row) }
    }

    @objc func morePressed() {
        if let row { owner?.showMenu(for: row, from: more) }
    }

    static func button(_ identifier: String, symbol: String? = nil, label: String? = nil) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityIdentifier(identifier)
        if let symbol, let label { set(button, symbol: symbol, label: label) }
        return button
    }

    /// The icon, its tooltip and what VoiceOver and the harness read.
    static func set(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
}

/// Show Versions: each version under its label, selectable so any of them can be
/// copied, scrolling once a long hands-free Dictation would outgrow the sheet.
enum VersionsView {
    static let width: CGFloat = 440

    static func make(_ sections: [(label: String, text: String)]) -> NSView {
        let shown = NSMutableAttributedString()
        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
        ]
        for (index, section) in sections.enumerated() {
            shown.append(NSAttributedString(string: (index == 0 ? "" : "\n\n") + section.label + "\n", attributes: label))
            shown.append(NSAttributedString(string: section.text, attributes: body))
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textStorage?.setAttributedString(shown)
        let height = shown.boundingRect(with: NSSize(width: width - 16, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: min(ceil(height) + 8, 420))
        return scroll
    }
}

/// Settings: Private mode, cloud model, local model (install / remove), mic,
/// API keys (Keychain), start at login. NSGridView of plain controls. Layout is fog.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: PreferencesStore, secrets: Secrets) { fatalError("not implemented") }
    required init?(coder: NSCoder) { fatalError("not implemented") }
}
