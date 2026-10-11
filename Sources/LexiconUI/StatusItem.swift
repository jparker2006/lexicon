public import AppKit
import LexiconDomain
import LexiconCore

/// The menu bar icon: the logo drawn in code, a template image while idle and
/// in color with a badge while a Dictation is active (`render`). Clicking it
/// opens the menu: name and version, whatever the shell adds, then Quit. The menu
/// is rebuilt each time it opens, so its lines are always current.
/// Its `AXIdentifier` (`AccessibilityID.statusItem`) is how `lexicon-harness` finds it.
/// While a permission is missing, an orange dot shows on the idle icon, and a left
/// click opens that setup step instead of the menu (a right click still opens the menu).
///
/// Still to come: History on left click and Settings (#63, #69), Private mode
/// and the outlined logo (#68).
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    let appName: String
    let version: String
    let extraItems: @MainActor () -> [NSMenuItem]
    let menu = NSMenu()
    /// The last state drawn, so a change to `warning` redraws it.
    private var state: IndicatorState = .hidden

    /// The permission step the warning dot points at, or nil for no dot.
    public var warning: SetupStep? {
        didSet { if warning != oldValue { render(state, open: 0) } }
    }
    /// Called with that step when the dot shows and the icon is left-clicked.
    public var onWarningClick: (@MainActor (SetupStep) -> Void)?

    /// `appName` is "Lexicon" or "Lexicon Dev"; `version` is shown after it in the title line.
    public init(appName: String, version: String, extraItems: @escaping @MainActor () -> [NSMenuItem] = { [] }) {
        self.appName = appName
        self.version = version
        self.extraItems = extraItems
        // Variable: a badge makes the icon wider while a Dictation is active.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.setAccessibilityIdentifier(AccessibilityID.statusItem)
        render(.hidden)
        // No item.menu: a set menu takes every click, and clicked() decides between setup and the menu.
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        menu.delegate = self
    }

    @objc private func clicked() {
        // performClick below can send the action again; a set menu means it is already opening.
        if item.menu != nil { return }
        let event = NSApp.currentEvent
        let leftClick = event?.type == .leftMouseDown && !(event?.modifierFlags.contains(.control) ?? false)
        if leftClick, showsDot, let warning, let onWarningClick {
            onWarningClick(warning)
            return
        }
        // Shown the standard way, so it tracks like any status item menu.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "\(appName) \(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let extras = extraItems()
        if !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Shows `state`; `open` 0...1 opens the logo's mouth with the voice while recording.
    func render(_ state: IndicatorState, open: CGFloat = 0) {
        self.state = state
        guard let button = item.button else { return }
        let look = Self.look(state)
        // A Dictation's own label wins while it is active; otherwise the dot names the missing permission.
        let words = look.label ?? warning.map(SetupCopy.warningLabel)
        let label = words.map { "Lexicon: \($0)" } ?? "Lexicon"
        button.image = showsDot
            ? Self.warningImage(description: label)
            : LogoMark.image(open: look.opens ? open : 0, color: look.color, badge: look.badge,
                             description: label)
        button.setAccessibilityLabel(label)
    }

    /// Only the bare idle icon shows the dot. A Dictation's color or badge keeps its own look,
    /// since the dot image has no badge to draw.
    private var showsDot: Bool {
        let look = Self.look(state)
        return warning != nil && look.color == nil && look.badge == nil
    }

    /// The idle icon with the dot. Not a template, or the menu bar would tint the dot away;
    /// `labelColor` resolves for the menu bar's appearance each time the handler draws.
    private static func warningImage(description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.labelColor.setFill()
            LogoMark.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18).insetBy(dx: 1, dy: 1), open: 0)
            // A clear ring keeps the dot off the logo's edge.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 18 - 8.5, y: 18 - 8.5, width: 10, height: 10)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18 - 7, y: 18 - 7, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }

    /// Exhaustive: a new state fails the build here until it has its look.
    private static func look(_ state: IndicatorState) -> (color: NSColor?, badge: String?, label: String?, opens: Bool) {
        switch state {
        case .hidden: (nil, nil, nil, false)
        case .recording(let mode, let minuteLeft):
            (minuteLeft ? .systemOrange : .systemRed,
             minuteLeft ? "timer" : mode == .handsFree ? "lock.fill" : nil,
             (mode == .handsFree ? "recording hands-free" : "recording") + (minuteLeft ? ", 1 min left" : ""),
             true)
        case .finishing: (nil, "ellipsis", "finishing", false)
        case .landed: (.systemGreen, "checkmark", "typed", false)
        case .pasteLast: (.controlAccentColor, "doc.on.clipboard", "not typed", false)
        case .error: (.systemOrange, "exclamationmark", "error", false)
        }
    }
}
