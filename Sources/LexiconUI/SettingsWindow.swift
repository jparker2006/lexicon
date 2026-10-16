public import AppKit
public import LexiconCore
import LexiconDomain
import os

/// Opens the Keys form from the menu bar. Its window and rows exist only while
/// the form is open, apart from the one warm-up build after launch, dropped at
/// once; each opening begins with blank secure fields.
@MainActor
public final class SettingsWindowPresenter: NSObject {
    private let credentials: CredentialCommand
    private var controller: KeysWindowController?
    private let log = Logger(subsystem: "Lexicon", category: "Settings")

    #if DEBUG
    public var credentialFieldsAreEmpty: Bool {
        controller?.credentialFieldsAreEmpty ?? true
    }
    #endif

    public init(credentials: @escaping CredentialCommand) {
        self.credentials = credentials
    }

    /// The menu bar menu's Settings line.
    public func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings…", action: #selector(show), keyEquivalent: "")
        item.target = self
        item.setAccessibilityIdentifier(AccessibilityID.settingsMenu)
        return item
    }

    @objc public func show() {
        // From the open request, so activating the app counts too.
        let clock = ContinuousClock()
        let opened = clock.now
        KeyEquivalents.install()
        NSApp.activate()
        if let controller {
            controller.showWindow(nil)
            return
        }

        let controller = KeysWindowController(credentials: credentials) { [weak self] in
            self?.controller = nil
        }
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.displayIfNeeded()
        // The 100 ms budget is timed inside Lexicon, open request to the grid drawn, the way
        // History's open is (DECISIONS item 105). Availability is asked for after it.
        let ms = (clock.now - opened) / .milliseconds(1)
        log.notice("Settings window: usable grid drawn \(Int(ms.rounded()), privacy: .public) ms after open")
        controller.requestAvailability()
    }

    /// Builds the form once, unshown, and drops it, as History's warm-up does (DECISIONS
    /// item 106): a process's first form pays AppKit's one-time setup (the grid, the
    /// secure fields), which made the first open the slowest. It asks for no credential.
    /// Returns the controller it built (nil while Settings is open) for the caller to drop.
    @discardableResult
    public func warmUp() -> NSWindowController? {
        guard controller == nil else { return nil }
        return KeysWindowController(credentials: { _, _ in }) {}
    }
}

@MainActor
private struct SettingsCredentialRow {
    let id: CredentialID
    let entry: NSSecureTextField
    let status: NSTextField
    let save: NSButton
    let remove: NSButton
}

@MainActor
private final class KeysWindowController: NSWindowController, NSWindowDelegate {
    private let credentials: CredentialCommand
    private let onClose: @MainActor () -> Void
    private var rows: [CredentialID: SettingsCredentialRow] = [:]
    private var operationGenerations: [CredentialID: UInt64] = [:]
    private var formGeneration: UInt64 = 0
    private var didRequestAvailability = false
    private var isClosed = false

    #if DEBUG
    var credentialFieldsAreEmpty: Bool {
        rows.values.allSatisfy { row in
            let editorIsEmpty = (row.entry.currentEditor() as? NSTextView)?.string.isEmpty ?? true
            return row.entry.stringValue.isEmpty && editorIsEmpty
        }
    }
    #endif

    init(credentials: @escaping CredentialCommand, onClose: @escaping @MainActor () -> Void) {
        self.credentials = credentials
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 184),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        super.init(window: window)

        window.title = "Settings"
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(AccessibilityID.settingsWindow)
        window.delegate = self
        window.center()

        let grid = NSGridView(views: Self.makeViews(controller: self, rows: &rows))
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        // A plain NSGridView is ignored by accessibility, which would leave its
        // identifier unreachable and its rows loose in the window.
        grid.setAccessibilityElement(true)
        grid.setAccessibilityRole(.group)
        grid.setAccessibilityLabel("Keys")
        grid.setAccessibilityIdentifier(AccessibilityID.settingsGrid)

        let content = NSView()
        content.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 740, height: CGFloat(rows.count) * 42 + 36))
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func requestAvailability() {
        guard !didRequestAvailability, !isClosed else { return }
        didRequestAvailability = true
        formGeneration &+= 1
        let form = formGeneration
        for (id, _) in Self.rowDefinitions {
            request(.availability(id), for: id, form: form, progress: "Checking…")
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        closeForm()
    }

    private func closeForm() {
        guard !isClosed else { return }
        isClosed = true
        formGeneration &+= 1
        for row in rows.values {
            clear(row.entry)
        }
        rows.removeAll()
        operationGenerations.removeAll()
        onClose()
    }

    @objc private func save(_ sender: NSButton) {
        guard let row = rows.values.first(where: { $0.save === sender }), !isClosed else { return }
        let id = row.id
        let value: String
        if let editor = row.entry.currentEditor() as? NSTextView {
            value = editor.string
        } else {
            value = row.entry.stringValue
        }
        clear(row.entry)
        request(.save(id, value), for: id, form: formGeneration, progress: "Saving…")
    }

    @objc private func remove(_ sender: NSButton) {
        guard let row = rows.values.first(where: { $0.remove === sender }), !isClosed else { return }
        request(.remove(row.id), for: row.id, form: formGeneration, progress: "Removing…")
    }

    private func request(_ edit: CredentialEdit, for id: CredentialID, form: UInt64, progress: String) {
        guard !isClosed, let row = rows[id] else { return }
        let operation = (operationGenerations[id] ?? 0) &+ 1
        operationGenerations[id] = operation
        row.status.stringValue = progress

        credentials(edit) { [weak self, id, form, operation] outcome in
            Task { @MainActor [weak self] in
                self?.receive(outcome, for: id, form: form, operation: operation)
            }
        }
    }

    private func receive(_ outcome: CredentialOutcome, for id: CredentialID, form: UInt64, operation: UInt64) {
        guard !isClosed,
              form == formGeneration,
              operationGenerations[id] == operation,
              let row = rows[id] else { return }

        switch outcome {
        case .availability(.saved), .saved:
            row.status.stringValue = "Saved"
        case .availability(.missing), .removed:
            row.status.stringValue = "Missing"
        case .availability(.unavailable), .unavailable:
            row.status.stringValue = "Unavailable"
        case .emptyEntry:
            row.status.stringValue = "Enter a key"
        case .refused:
            row.status.stringValue = "Could not change key"
        }
    }

    private func clear(_ field: NSSecureTextField) {
        (field.currentEditor() as? NSTextView)?.string = ""
        field.stringValue = ""
    }

    private static func makeViews(
        controller: KeysWindowController,
        rows: inout [CredentialID: SettingsCredentialRow]
    ) -> [[NSView]] {
        return rowDefinitions.map { id, title in
            let label = NSTextField(labelWithString: title)
            label.alignment = .right

            let entry = NSSecureTextField(string: "")
            entry.placeholderString = "API key"
            entry.setAccessibilityIdentifier(AccessibilityID.settingsEntry(id))

            let status = NSTextField(labelWithString: "Checking…")
            status.setAccessibilityIdentifier(AccessibilityID.settingsStatus(id))

            let save = NSButton(title: "Save", target: controller, action: #selector(save(_:)))
            save.setAccessibilityIdentifier(AccessibilityID.settingsSave(id))

            let remove = NSButton(title: "Remove", target: controller, action: #selector(remove(_:)))
            remove.setAccessibilityIdentifier(AccessibilityID.settingsRemove(id))

            rows[id] = SettingsCredentialRow(id: id, entry: entry, status: status, save: save, remove: remove)
            return [label, entry, status, save, remove]
        }
    }

    private static var rowDefinitions: [(CredentialID, String)] {
        CloudModel.allCases.map { (.speech($0), $0.displayName) } + [
            (.cleanup, "OpenRouter"),
            (.jev, "TypeSafe")
        ]
    }
}
