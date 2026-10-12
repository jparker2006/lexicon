import AppKit
import LexiconDomain
import LexiconUI

// The History window and the Lexicon page, each opened from the menu.

extension AppDelegate {
    /// Both presenters; neither builds its window until it is first shown.
    func makeWindows(paths: AppPaths) -> HistoryWindowPresenter {
        let history = HistoryWindowPresenter(paths: paths, system: system)
        self.history = history
        // The system's Lexicon, the one every Dictation reads, so the page's edits reach the next fn-down.
        lexiconPage = system.map { LexiconWindowPresenter(lexicon: $0.lexicon) }
        return history
    }

    /// Reopened from Spotlight or Finder: open History.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        history?.show()
        return false
    }
}
