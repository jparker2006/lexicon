import AppKit
import LexiconDomain

/// What the setup window's buttons do. The coordinator (Setup) supplies them.
struct SetupWindowActions {
    var allowMicrophone: @MainActor () -> Void      // Microphone row's button (both "Allow Microphone" and "Open System Settings")
    var openAccessibility: @MainActor () -> Void    // Accessibility row's "Open System Settings"
    var restart: @MainActor () -> Void              // Accessibility row's "Restart Lexicon"
    var downloadModel: @MainActor () -> Void        // Speech model row's "Download" / "Try Again"
    var openKeyboardSettings: @MainActor () -> Void // globe key line's button
    var triedFn: @MainActor () -> Void              // called once when the try field's text first becomes non-empty
}

/// The first-run setup window: a row per SetupStep, the globe key line and Done.
/// It draws only what SetupCopy says, so the words Jake reads are the tested ones.
/// Closing drops the controller; the next open builds a fresh one.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let actions: SetupWindowActions
    let onClose: @MainActor () -> Void
    private let stack = NSStackView()
    private var rows: [SetupStep: SetupRowView] = [:]
    private let tryField = NSTextField(string: "")
    private let globeDetail = NSTextField(wrappingLabelWithString: "")
    private let globeButton = NSButton(title: "", target: nil, action: nil)
    /// The facts last drawn. Accessibility's button reads them: Restart when trust is granted, Open otherwise.
    private var facts: SetupFacts?
    /// True once the window has a place: a saved frame, or centered at the first show.
    private var positioned = false
    /// Only the first keystroke reports to the coordinator, which keeps the fact.
    private var reportedTry = false

    init(actions: SetupWindowActions, onClose: @escaping @MainActor () -> Void) {
        self.actions = actions
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SetupLayout.width, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init(window: window)
        window.title = "Set Up Lexicon"
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(AccessibilityID.setupWindow)
        window.delegate = self
        positioned = window.setFrameUsingName("Setup")
        window.setFrameAutosaveName("Setup")

        stack.orientation = .vertical
        // Leading plus explicit widths (`fill`): with `.width` alignment, a label
        // hugged its text and sat against the right margin (live check).
        stack.alignment = .leading
        stack.spacing = SetupLayout.spacing
        stack.edgeInsets = NSEdgeInsets(top: SetupLayout.inset, left: SetupLayout.inset,
                                        bottom: SetupLayout.inset, right: SetupLayout.inset)
        for step in SetupStep.allCases {
            let row = SetupRowView(step: step, target: self, action: #selector(rowButtonClicked(_:)))
            rows[step] = row
            stack.addArrangedSubview(row)
        }
        tryField.placeholderString = "Your words land here"
        tryField.setAccessibilityIdentifier(AccessibilityID.setupTryField)
        tryField.delegate = self
        tryField.isEnabled = false
        rows[.tryFn]?.column.addArrangedSubview(tryField)
        rows[.tryFn].map { tryField.fill($0.column) }

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)

        globeDetail.textColor = .secondaryLabelColor
        globeDetail.preferredMaxLayoutWidth = SetupLayout.contentWidth
        globeDetail.setContentCompressionResistancePriority(.required, for: .vertical)
        globeButton.bezelStyle = .rounded
        globeButton.target = self
        globeButton.action = #selector(openKeyboardSettingsClicked(_:))
        let globe = NSStackView(views: [globeDetail, globeButton])
        globe.orientation = .vertical
        globe.alignment = .leading
        stack.addArrangedSubview(globe)
        globeDetail.fill(globe)

        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked(_:)))
        done.bezelStyle = .rounded
        // No Return key: Jake may press Return in the try box, and that must not close setup.
        let footer = NSStackView()
        footer.addView(done, in: .trailing)
        stack.addArrangedSubview(footer)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalToConstant: SetupLayout.contentWidth).isActive = true
        }

        window.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Redraws every row from `facts`. Cheap and idempotent: called on every poll, so
    /// nothing is set unless a fact changed.
    func render(_ facts: SetupFacts) {
        guard facts != self.facts else { return }
        self.facts = facts
        for step in SetupStep.allCases {
            rows[step]?.show(SetupCopy.row(step, facts))
        }
        tryField.isEnabled = facts.isDone(.tryFn) || facts.current == .tryFn
        let globe = SetupCopy.globeKey(ok: facts.globeKeyOK)
        globeDetail.stringValue = globe.detail
        globeButton.title = globe.button ?? ""
        globeButton.isHidden = globe.button == nil
        fitWindow()
    }

    /// Brings the window forward. For .tryFn the try field takes the keyboard, so the
    /// first Dictation lands there without a click.
    func focus(_ step: SetupStep?) {
        KeyEquivalents.install()
        NSApp.activate()
        if !positioned {
            positioned = true
            window?.center()
        }
        showWindow(nil)
        // Activation can be refused while another app is in front (the dot's click
        // left it behind System Settings in the live check), so order it front anyway.
        window?.orderFrontRegardless()
        if step == .tryFn { window?.makeFirstResponder(tryField) }
    }

    /// The window is as tall as its rows, which change with the facts (a progress bar,
    /// a longer detail). It resizes from the top, where Jake last left it.
    private func fitWindow() {
        guard let window else { return }
        let height = stack.fittingSize.height
        guard window.contentLayoutRect.height != height else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: SetupLayout.width, height: height))
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    @objc private func rowButtonClicked(_ sender: NSButton) {
        guard let step = SetupStep(rawValue: sender.tag) else { return }
        switch step {
        case .microphone:
            actions.allowMicrophone()
        case .accessibility:
            // Trust granted but fn still off: only a relaunch starts the fn tap.
            if facts?.accessibility == true {
                actions.restart()
            } else {
                actions.openAccessibility()
            }
        case .model:
            actions.downloadModel()
        case .tryFn:
            break
        }
    }

    @objc private func openKeyboardSettingsClicked(_ sender: NSButton) {
        actions.openKeyboardSettings()
    }

    @objc private func doneClicked(_ sender: NSButton) {
        window?.performClose(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !reportedTry, !tryField.stringValue.isEmpty else { return }
        reportedTry = true
        actions.triedFn()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// One step's row: the status symbol, then a column holding the title line (the
/// title, with the step's button at its trailing end), the detail, the model's
/// progress bar, and whatever the step adds under its text (the try field). The
/// button sits on the title line so the detail keeps the full column width.
@MainActor
private final class SetupRowView: NSStackView {
    let column = NSStackView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    /// What the row last drew, so a poll that changes nothing sets nothing.
    private var shown: SetupRow?

    init(step: SetupStep, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = SetupLayout.iconGap
        distribution = .fill

        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: SetupLayout.iconWidth).isActive = true

        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detail.font = .systemFont(ofSize: NSFont.systemFontSize)
        detail.preferredMaxLayoutWidth = SetupLayout.textWidth
        detail.setContentCompressionResistancePriority(.required, for: .vertical)

        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.tag = step.rawValue
        button.target = target
        button.action = action
        let header = NSStackView()
        header.addView(title, in: .leading)
        header.addView(button, in: .trailing)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.widthAnchor.constraint(equalToConstant: SetupLayout.textWidth).isActive = true
        for view in [header, detail, progress] {
            column.addArrangedSubview(view)
            view.fill(column)
        }

        addArrangedSubview(icon)
        addArrangedSubview(column)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(_ row: SetupRow) {
        guard row != shown else { return }
        shown = row
        switch row.state {
        case .done:
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
            icon.contentTintColor = .systemGreen
        case .current:
            icon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "To do")
            icon.contentTintColor = .controlAccentColor
        case .waiting:
            icon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Waiting")
            icon.contentTintColor = .tertiaryLabelColor
        }
        let waiting = row.state == .waiting
        title.stringValue = row.title
        title.textColor = waiting ? .tertiaryLabelColor : .labelColor
        detail.stringValue = row.detail
        detail.textColor = waiting ? .tertiaryLabelColor : .secondaryLabelColor
        button.title = row.button ?? ""
        button.isHidden = row.button == nil
        button.isEnabled = row.state == .current
        progress.isHidden = row.progress == nil
        progress.doubleValue = row.progress ?? 0
    }
}

private extension NSView {
    /// As wide as `stack`, whose alignment would otherwise let it hug its content.
    func fill(_ stack: NSStackView) {
        widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

/// The window's fixed geometry. Each wrapping label gets its width here, so its
/// height is known before a layout pass (the window is sized to its rows).
private enum SetupLayout {
    static let width: CGFloat = 460
    static let inset: CGFloat = 20
    static let spacing: CGFloat = 14
    static let iconWidth: CGFloat = 20
    static let iconGap: CGFloat = 12
    static let contentWidth: CGFloat = width - 2 * inset
    static let textWidth: CGFloat = contentWidth - iconWidth - iconGap
}
