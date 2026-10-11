public import AppKit
import os
import LexiconDomain
public import WordStore

/// Opens the Lexicon page from the menu bar. One window at a time; a second open
/// brings it forward. Closing drops the window and its copy of the list. The
/// Lexicon itself is the app's one store, the same actor every Dictation reads
/// at fn-down, so an edit here reaches the next Dictation.
@MainActor
public final class LexiconWindowPresenter: NSObject {
    private let lexicon: Lexicon
    private var controller: LexiconWindowController?

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    /// The menu bar menu's "Lexicon" line.
    public func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Lexicon", action: #selector(show), keyEquivalent: "")
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
        let controller = LexiconWindowController(lexicon: lexicon) { [weak self] in
            self?.controller = nil
        }
        self.controller = controller
        controller.showWindow(nil)
    }
}

/// The Lexicon page, Wispr-style: one plain list of Terms and Rules (Rules as
/// `heard → written`, ✨ on anything learned), a search field, Add new and
/// Import. Each row has a delete button; Delete deletes the selected row.
///
/// The list is a copy, read again after every change and whenever the window
/// comes forward, so it never drifts from the store.
@MainActor
final class LexiconWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
    NSToolbarDelegate {
    let lexicon: Lexicon
    let onClose: @MainActor () -> Void
    let table = LexiconTable()
    let search = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
    let importItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("import"))
    let addItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("add"))
    let empty = NSTextField(labelWithString: "")
    let addField = NSTextField(string: "")
    /// Everything in the Lexicon, sorted; `shown` is what the search leaves of it.
    var all: [LexiconEntry] = []
    var shown: [LexiconEntry] = []
    /// Reads are async: only the newest one may set the list.
    var reads = 0
    private let log = Logger(subsystem: "Lexicon", category: "Lexicon page")

    init(lexicon: Lexicon, onClose: @escaping @MainActor () -> Void) {
        self.lexicon = lexicon
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init(window: window)
        window.title = "Lexicon"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 260)
        window.setAccessibilityIdentifier(AccessibilityID.lexiconWindow)
        window.delegate = self
        if !window.setFrameUsingName("Lexicon") { window.center() }
        window.setFrameAutosaveName("Lexicon")

        let toolbar = NSToolbar(identifier: "Lexicon")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        search.searchField.placeholderString = "Search"
        search.searchField.target = self
        search.searchField.action = #selector(searched(_:))
        search.searchField.setAccessibilityIdentifier(AccessibilityID.lexiconSearch)
        for (item, title, action, id) in [(importItem, "Import…", #selector(importFile(_:)), AccessibilityID.lexiconImport),
                                          (addItem, "Add new", #selector(addNew(_:)), AccessibilityID.lexiconAdd)] {
            let button = NSButton(title: title, target: self, action: action)
            button.setAccessibilityIdentifier(id)
            item.view = button
            item.label = title
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 30
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityIdentifier(AccessibilityID.lexiconTable)
        table.onDelete = { [weak self] row in self?.remove(row: row) }
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        // Hidden until the first read, so an open never flashes "No Terms or Rules yet".
        empty.isHidden = true
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
        Task { await reload() }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Reads the Lexicon again, then selects and scrolls to `selecting` (an
    /// entry just added) or to row `selectingRow` (where a deleted row was).
    func reload(selecting entry: LexiconEntry? = nil, selectingRow: Int? = nil) async {
        reads += 1
        let read = reads
        let entries = LexiconText.sorted(await lexicon.entries)
        guard read == reads else { return }
        all = entries
        filter()
        let row = entry.flatMap { entry in shown.firstIndex { LexiconText.isSame($0, entry) } }
            ?? selectingRow.map { min($0, shown.count - 1) }
        if let row, row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    func filter() {
        shown = all.filter { LexiconText.matches($0, search.searchField.stringValue) }
        empty.stringValue = all.isEmpty ? "No Terms or Rules yet" : "No matches"
        empty.isHidden = !shown.isEmpty
        table.reloadData()
    }

    @objc func searched(_ sender: NSSearchField) {
        filter()
        table.scrollRowToVisible(0)
    }

    // MARK: Delete

    @objc func deleteClicked(_ sender: NSButton) {
        remove(row: table.row(for: sender))
    }

    func remove(row: Int) {
        guard shown.indices.contains(row) else { return }
        let entry = shown[row]
        Task {
            do {
                switch entry {
                case .term(let term): try await lexicon.remove(term)
                case .rule(let rule): try await lexicon.remove(rule)
                }
            } catch {
                log.error("delete failed: \(String(describing: error), privacy: .private)")
                NSSound.beep()
            }
            // The same row stays selected, so Delete again deletes the next one.
            await reload(selectingRow: row)
        }
    }

    // MARK: Add new

    /// A sheet with one field that takes a line of the import format: a Term,
    /// or a Rule as `heard -> written`.
    @objc func addNew(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled],
                             backing: .buffered, defer: true)
        let title = NSTextField(labelWithString: "Add to the Lexicon")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let hint = NSTextField(wrappingLabelWithString: "A Term is a word always written one way. A Rule is heard -> written.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        addField.stringValue = ""
        addField.placeholderString = "gstack, or codecs -> Codex"
        addField.setAccessibilityIdentifier(AccessibilityID.lexiconAddField)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAdd(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let add = NSButton(title: "Add", target: self, action: #selector(addTyped(_:)))
        add.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, add])
        let stack = NSStackView(views: [title, addField, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(12, after: hint)
        NSLayoutConstraint.activate([
            addField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            hint.widthAnchor.constraint(equalTo: addField.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: addField.trailingAnchor),
        ])
        sheet.contentView = stack
        sheet.initialFirstResponder = addField
        window.beginSheet(sheet)
    }

    @objc func cancelAdd(_ sender: Any?) {
        guard let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet)
    }

    /// Adds the typed line, replacing an entry with the same Term or heard side:
    /// typing a spelling means that spelling. Anything but one entry beeps and
    /// keeps the sheet open.
    @objc func addTyped(_ sender: Any?) {
        // The page shows Rules with "→", so a Rule typed the way it is shown is one too.
        let line = addField.stringValue.replacingOccurrences(of: "→", with: "->")
        let file = LexiconFile(parsing: line)
        guard let window, let sheet = window.attachedSheet, file.entries.count == 1, file.unreadable == 0,
              let entry = file.entries.first else {
            NSSound.beep()
            return
        }
        window.endSheet(sheet)
        if !LexiconText.matches(entry, search.searchField.stringValue) { search.searchField.stringValue = "" }
        Task {
            do {
                switch entry {
                case .term(let term): try await lexicon.add(term)
                case .rule(let rule): try await lexicon.add(rule)
                }
            } catch {
                log.error("add failed: \(String(describing: error), privacy: .private)")
                NSSound.beep()
            }
            await reload(selecting: entry)
        }
    }

    // MARK: Import

    @objc func importFile(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "A text file with one entry per line: a Term, or a Rule as heard -> written."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importEntries(from: url)
        }
    }

    /// Adds what the file has that the Lexicon doesn't, then says so in counts.
    /// Counts only, in the alert and the log: the file may be private.
    func importEntries(from url: URL) {
        Task {
            let alert = NSAlert()
            do {
                let file = try LexiconFile(contentsOf: url)
                let counts = try await lexicon.add(file.entries)
                (alert.messageText, alert.informativeText) = LexiconText.summary(of: counts, unreadable: file.unreadable)
                log.notice("""
                    imported \(counts.terms, privacy: .public) Terms and \(counts.rules, privacy: .public) Rules; \
                    \(counts.duplicates, privacy: .public) already there, \(file.unreadable, privacy: .public) lines not read
                    """)
            } catch {
                alert.alertStyle = .warning
                alert.messageText = "Couldn't import that file"
                alert.informativeText = "Import reads a plain text file in UTF-8, one entry per line."
                log.error("import failed: \(String(describing: error), privacy: .private)")
            }
            await reload()
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: EntryCell.identifier, owner: nil) as? EntryCell
            ?? EntryCell(target: self, delete: #selector(deleteClicked(_:)))
        cell.show(shown[row])
        return cell
    }

    // MARK: Window

    /// Back from another app or another window: the Lexicon may have changed.
    func windowDidBecomeKey(_ notification: Notification) {
        Task { await reload() }
    }

    /// Closing drops the controller and its copy of the list.
    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [importItem.itemIdentifier, addItem.itemIdentifier, .flexibleSpace, search.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        [importItem, addItem, search].first { $0.itemIdentifier == itemIdentifier }
    }
}

/// Delete or forward delete removes the selected row.
final class LexiconTable: NSTableView {
    var onDelete: (Int) -> Void = { _ in }

    override func keyDown(with event: NSEvent) {
        guard event.specialKey == .delete || event.specialKey == .deleteForward, selectedRow >= 0 else {
            super.keyDown(with: event)
            return
        }
        onDelete(selectedRow)
    }
}

/// One Term or Rule, with its delete button at the end.
final class EntryCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("entry")
    let label = NSTextField(labelWithString: "")
    let delete = NSButton()

    init(target: AnyObject, delete action: Selector) {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = "Delete"
        delete.target = target
        delete.action = action
        delete.setAccessibilityIdentifier(AccessibilityID.lexiconDelete)
        for view in [label, delete] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            delete.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(_ entry: LexiconEntry) {
        let title = LexiconText.title(for: entry)
        label.stringValue = title
        delete.setAccessibilityLabel("Delete \(title)")
    }
}
