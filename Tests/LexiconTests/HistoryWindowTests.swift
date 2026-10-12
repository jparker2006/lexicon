import AppKit
import History
import LexiconDomain
import Testing
@testable import LexiconUI

// The History window's open path without a screen: the warm-up leaves nothing
// behind, the search field is a plain field in the title bar, and that field
// still filters. Nothing here orders a window front or activates the app; the
// live app checks the open itself.

/// A controller built the way the presenter builds one, over a throwaway root.
/// Never shown: the test never orders its window front.
@MainActor
private func unshownController(_ paths: AppPaths) -> HistoryWindowController {
    HistoryWindowController(reader: HistoryReader(paths: paths), system: nil,
                            pasteboard: NSPasteboard(name: .init(UUID().uuidString))) {}
}

/// A view and every view under it, depth first.
@MainActor
private func viewTree(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(viewTree)
}

@MainActor
@Test func warmingUpLeavesNothingBehindThatHoldsTheHistoryWindow() {
    _ = NSApplication.shared
    let paths = AppPaths.temporary()
    let presenter = HistoryWindowPresenter(paths: paths, system: nil)
    // The app drains its autorelease pool each turn of the run loop; the warm-up's window must go with it.
    autoreleasepool { presenter.warmUp() }

    // AppKit refuses a frame autosave name while another live window holds it. A
    // warm-up window that outlived its drop would take "History" from the real
    // window, which would then forget its place.
    let controller = unshownController(paths)
    #expect(controller.window?.frameAutosaveName == "History")
    // Nothing the warm-up built is on screen.
    #expect(!NSApplication.shared.windows.contains { $0.title == "History" && $0.isVisible })
}

@MainActor
@Test func theSearchFieldIsAPlainFieldInTheTitleBarAndTheWindowHasNoToolbar() {
    _ = NSApplication.shared
    let controller = unshownController(AppPaths.temporary())
    // A toolbar's search item cost about 20 ms of every open, so the window has none.
    #expect(controller.window?.toolbar == nil)

    // The field is the one with the History search identifier, and it sits in a title bar accessory.
    let accessories = controller.window?.titlebarAccessoryViewControllers ?? []
    let fields = accessories.flatMap { viewTree($0.view) }
        .compactMap { $0 as? NSSearchField }
        .filter { $0.accessibilityIdentifier() == AccessibilityID.historySearch }
    #expect(fields.count == 1)
    #expect(fields.first === controller.search)

    // Its accessory sits at the title bar's trailing end, where the toolbar's search sat.
    let holder = accessories.first { accessory in viewTree(accessory.view).contains { $0 === controller.search } }
    #expect(holder?.layoutAttribute == .trailing)
}

@MainActor
@Test func theSearchFieldStillFiltersAndSaysWhenNothingMatches() {
    _ = NSApplication.shared
    // An empty History: nothing matches anything, and a cleared search says there are no Dictations yet.
    let controller = unshownController(AppPaths.temporary())
    #expect(controller.empty.stringValue == "No Dictations yet")

    controller.search.stringValue = "zebra"
    controller.searched(controller.search)
    #expect(controller.empty.stringValue == "No matches")
    #expect(controller.rowCount == 0)

    controller.search.stringValue = ""
    controller.searched(controller.search)
    #expect(controller.empty.stringValue == "No Dictations yet")
}
