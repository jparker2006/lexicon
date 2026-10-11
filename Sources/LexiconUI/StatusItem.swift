public import AppKit
import LexiconDomain
import LexiconCore

/// The menu bar icon: the logo drawn in code as a template image. Clicking it
/// opens the menu: name and version, whatever the shell adds, then Quit. The menu
/// is rebuilt each time it opens, so its lines are always current.
/// Its `AXIdentifier` (`AccessibilityID.statusItem`) is how `lexicon-harness` finds it.
///
/// Still to come: History on left click and Settings (#63, #69), Private mode
/// and the outlined logo (#68), start at login and the warning dot (#57).
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    let appName: String
    let version: String
    let extraItems: @MainActor () -> [NSMenuItem]

    /// `appName` is "Lexicon" or "Lexicon Dev"; `version` is shown after it in the title line.
    public init(appName: String, version: String, extraItems: @escaping @MainActor () -> [NSMenuItem] = { [] }) {
        self.appName = appName
        self.version = version
        self.extraItems = extraItems
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = LogoMark.templateImage()
            button.setAccessibilityIdentifier(AccessibilityID.statusItem)
        }
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

    /// Dictation state shown by swapping the image; active states draw in color (#55).
    func render(_ event: ConductorEvent) { fatalError("not implemented") }
}
