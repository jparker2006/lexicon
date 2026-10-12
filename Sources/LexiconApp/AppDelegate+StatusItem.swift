import AppKit
import LexiconCore
import LexiconUI

// The menu bar icon, its menu, and the indicator: the pill, the icon's states
// and the sounds.

extension AppDelegate {
    /// The indicator follows the Conductor's events and the mic's levels.
    func showStatusItem(history: HistoryWindowPresenter,
                        preferences: PreferencesStore) -> (StatusItemController, DictationIndicator) {
        let bundle = Bundle.main
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lexicon"
        let statusItem = StatusItemController(appName: appName, version: Self.version(of: bundle)) { [weak self] in
            [history.menuItem()] + (self?.lexiconPage.map { [$0.menuItem()] } ?? [])
                + (self?.systemError.map { [Self.line($0)] } ?? [])
                + (self?.setup?.menuItems() ?? [])
                + (self?.indicator.map { [$0.privateModeMenuItem(), $0.soundsMenuItem()] } ?? [])
        }
        let indicator = DictationIndicator(statusItem: statusItem, preferences: preferences)
        self.statusItem = statusItem
        self.indicator = indicator
        if let system {
            Task {
                await indicator.follow(await system.conductor.events(), levels: system.recorder.levels)
            }
        }
        return (statusItem, indicator)
    }

    /// A menu line that only informs.
    static func line(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// "0.1 (412, 4dfdca8)": marketing version, build number, commit (set by scripts/bundle.sh).
    static func version(of bundle: Bundle) -> String {
        let info = { (key: String) in bundle.object(forInfoDictionaryKey: key) as? String ?? "?" }
        return "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")), \(info("LexiconCommit")))"
    }
}
