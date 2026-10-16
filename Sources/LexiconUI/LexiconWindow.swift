public import AppKit
import os
import LexiconDomain
public import WordStore

/// Opens the Lexicon page from the menu bar. One window at a time; a second open
/// brings it forward. Closing drops the window and its copy of the list. Give it
/// the Lexicon the Conductor reads at fn-down (the system's), so an edit here
/// reaches the next Dictation; a second actor on the same file would not see it.
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

/// One row per exact spelling, with its heard-as forms and their learned marks.
/// Each row has a delete button; Delete confirms removal of the whole entry.
/// Each form has its own remove button, so one wrongly learned form can go
/// without the rest.
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
    var all: [DictionaryEntry] = []
    var shown: [DictionaryEntry] = []
    /// Reads are async: only the newest one may set the list.
    var reads = 0
    /// The newest form removal, kept so a test can wait for it.
    var pending: Task<Void, Never>?
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
        table.usesAutomaticRowHeights = true
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
        // Hidden until the first read, so an open never flashes an empty state.
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
        if let entry, let added = all.first(where: { LexiconText.contains($0, entry) }),
           !LexiconText.matches(added, search.searchField.stringValue) {
            search.searchField.stringValue = ""
        }
        filter()
        let row = entry.flatMap { entry in shown.firstIndex { LexiconText.contains($0, entry) } }
            ?? selectingRow.map { min($0, shown.count - 1) }
        if let row, row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    func filter() {
        shown = all.filter { LexiconText.matches($0, search.searchField.stringValue) }
        empty.stringValue = all.isEmpty ? "No entries yet" : "No matches"
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
        guard let window, window.attachedSheet == nil, shown.indices.contains(row) else { return }
        let entry = shown[row]
        let alert = NSAlert()
        alert.messageText = "Delete \(entry.spelling)?"
        alert.informativeText = "This removes \(LexiconText.title(for: entry))."
        alert.addButton(withTitle: "Delete").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.delete(entry, selectingRow: row)
        }
    }

    private func delete(_ entry: DictionaryEntry, selectingRow row: Int) {
        Task {
            do {
                for record in entry.records {
                    switch record {
                    case .term(let term): try await lexicon.remove(term)
                    case .rule(let rule): try await lexicon.remove(rule)
                    }
                }
            } catch {
                log.error("delete failed: \(String(describing: error), privacy: .private)")
                NSSound.beep()
            }
            // The same row stays selected, so Delete again deletes the next one.
            await reload(selectingRow: row)
        }
    }

    /// Removes one heard-as form at once: adding it back is one line, unlike a whole
    /// entry. A form that is its entry's only record would take the entry with it,
    /// so that one asks as Delete does.
    @objc func removeFormClicked(_ sender: FormButton) {
        guard window?.attachedSheet == nil, let rule = sender.rule else { return }
        let row = shown.firstIndex { $0.records.contains(.rule(rule)) }
        if let row, shown[row].records.count == 1 {
            remove(row: row)
            return
        }
        pending = Task {
            do {
                try await lexicon.remove(rule)
            } catch {
                log.error("remove form failed: \(String(describing: error), privacy: .private)")
                NSSound.beep()
            }
            await reload(selectingRow: row)
        }
    }

    // MARK: Add new

    /// One field that takes a spelling or a heard-as line in the import format.
    @objc func addNew(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled],
                             backing: .buffered, defer: true)
        let title = NSTextField(labelWithString: "Add to the Lexicon")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let hint = NSTextField(wrappingLabelWithString: "Enter a spelling, or a heard-as form as heard -> written.")
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
        guard let window, let sheet = window.attachedSheet, let entry = LexiconText.entry(typed: addField.stringValue) else {
            NSSound.beep()
            return
        }
        window.endSheet(sheet)
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
        panel.message = "A text file with one spelling or heard-as form per line: heard -> written."
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
                let counts = try await lexicon.add(contentsOf: url)
                (alert.messageText, alert.informativeText) = LexiconText.summary(of: counts)
                log.notice("""
                    imported \(counts.terms, privacy: .public) Terms and \(counts.rules, privacy: .public) Rules; \
                    \(counts.duplicates, privacy: .public) already there, \(counts.unreadable, privacy: .public) lines not read
                    """)
            } catch {
                alert.alertStyle = .warning
                (alert.messageText, alert.informativeText) = LexiconText.importFailure
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
            ?? EntryCell(target: self, delete: #selector(deleteClicked(_:)), removeForm: #selector(removeFormClicked(_:)))
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

/// A heard-as form's remove button, carrying the form it removes.
final class FormButton: NSButton {
    var rule: Rule?
}

/// One dictionary entry: its spelling, then a line per heard-as form with that
/// form's remove button, and the entry's delete button at the end.
final class EntryCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("entry")
    let label = NSTextField(wrappingLabelWithString: "")
    let delete = NSButton()
    let lines = NSStackView()
    private(set) var formLabels: [NSTextField] = []
    private(set) var formButtons: [FormButton] = []
    private weak var target: AnyObject?
    private let removeForm: Selector

    init(target: AnyObject, delete action: Selector, removeForm: Selector) {
        self.target = target
        self.removeForm = removeForm
        super.init(frame: .zero)
        identifier = Self.identifier
        label.maximumNumberOfLines = 0
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.addArrangedSubview(label)
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = "Delete"
        delete.target = target
        delete.action = action
        delete.setAccessibilityIdentifier(AccessibilityID.lexiconDelete)
        for view in [lines, delete] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            delete.leadingAnchor.constraint(greaterThanOrEqualTo: lines.trailingAnchor, constant: 8),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// A reused cell drops the last entry's form lines before drawing this one's.
    func show(_ entry: DictionaryEntry) {
        let title = LexiconText.title(for: entry)
        label.stringValue = entry.spelling
        setAccessibilityLabel(title)
        delete.setAccessibilityLabel("Delete \(title)")
        for view in lines.arrangedSubviews where view !== label { view.removeFromSuperview() }
        formLabels = []
        formButtons = []
        for rule in entry.forms {
            let text = NSTextField(wrappingLabelWithString: LexiconText.formLine(rule))
            text.maximumNumberOfLines = 0
            text.textColor = .secondaryLabelColor
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let button = FormButton()
            button.rule = rule
            button.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Remove")
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "Remove this heard-as form"
            button.target = target
            button.action = removeForm
            button.setAccessibilityIdentifier(AccessibilityID.lexiconRemoveForm)
            button.setAccessibilityLabel("Remove heard-as form \(rule.heard) from \(entry.spelling)")
            let line = NSStackView(views: [text, button])
            line.spacing = 4
            lines.addArrangedSubview(line)
            formLabels.append(text)
            formButtons.append(button)
        }
    }
}
