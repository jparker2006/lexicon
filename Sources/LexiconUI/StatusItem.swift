public import AppKit
import LexiconDomain
import LexiconCore

/// The menu bar icon: the logo drawn in code, a template image while idle and
/// in color with a badge while a Dictation is active (`render`). Private mode
/// draws the logo as an outline and says so in the label (`setPrivate`). Clicking
/// it opens the menu: name and version, whatever the shell adds, then Quit. The menu
/// is rebuilt each time it opens, so its lines are always current.
/// Its `AXIdentifier` (`AccessibilityID.statusItem`) is how `lexicon-harness` finds it.
///
/// Still to come: History on left click and Settings (#63, #69), start at login
/// and the warning dot (#57).
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    let appName: String
    let version: String
    let extraItems: @MainActor () -> [NSMenuItem]
    /// Changed only by `setPrivate`, which redraws the icon.
    private(set) var isPrivate = false
    /// The last state rendered, so `setPrivate` can redraw it.
    private var shown: (state: IndicatorState, open: CGFloat) = (.hidden, 0)

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
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
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
        shown = (state, open)
        guard let button = item.button else { return }
        let look = Self.look(state)
        let label = Self.accessibilityLabel(for: state, isPrivate: isPrivate)
        button.image = LogoMark.image(open: look.opens ? open : 0, color: look.color, badge: look.badge,
                                      outlined: isPrivate, description: label)
        button.setAccessibilityLabel(label)
    }

    /// Private mode on or off, redrawing the current state.
    func setPrivate(_ on: Bool) {
        isPrivate = on
        render(shown.state, open: shown.open)
    }

    /// Private mode is named here so the harness and VoiceOver can tell it apart from the icon alone.
    static func accessibilityLabel(for state: IndicatorState, isPrivate: Bool) -> String {
        let label = look(state).label.map { "Lexicon: \($0)" } ?? "Lexicon"
        return isPrivate ? label + ", Private mode" : label
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
