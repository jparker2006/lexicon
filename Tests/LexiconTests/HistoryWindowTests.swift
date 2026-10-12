import Foundation
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
    // A pasteboard of its own, never Jake's clipboard, should a test ever click a row.
    HistoryWindowController(reader: HistoryReader(paths: paths), system: nil, pasteboard: .withUniqueName()) {}
}

@MainActor
@Test func warmingUpLeavesNothingBehindThatHoldsTheHistoryWindow() {
    let paths = AppPaths.temporary()
    let presenter = HistoryWindowPresenter(paths: paths, system: nil)
    // The app drains its autorelease pool each turn of the run loop; the warm-up's window must go with it.
    autoreleasepool { _ = presenter.warmUp() }

    // AppKit refuses a frame autosave name while another live window holds it. A
    // warm-up window that outlived its drop would keep "History", and the real
    // window would be refused it and forget its place.
    let controller = unshownController(paths)
    #expect(controller.window?.frameAutosaveName == "History")
}

@MainActor
@Test func theWarmUpReadsNothingFromHistory() async throws {
    // The spec has History load only rows on screen; the warm-up has no screen.
    let paths = AppPaths.temporary()
    let store = try HistoryStore(paths: paths)
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: Date(), app: AppContext(
        bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)))
    await store.flush()
    let presenter = HistoryWindowPresenter(paths: paths, system: nil)
    #expect(unshownController(paths).rowCount > 0, "the History the window would read has a row")
    #expect((presenter.warmUp() as? HistoryWindowController)?.rowCount == 0)
}

@MainActor
@Test func theSearchFieldIsAPlainFieldInTheTitleBarAndTheWindowHasNoToolbar() {
    let controller = unshownController(AppPaths.temporary())
    // Building a toolbar's search item cost a large share of every open, so the window has none.
    #expect(controller.window?.toolbar == nil)

    // The field carries the History search identifier and sits in a title bar
    // accessory at the trailing end, where the toolbar's search sat.
    #expect(controller.search.accessibilityIdentifier() == AccessibilityID.historySearch)
    let accessories = controller.window?.titlebarAccessoryViewControllers ?? []
    let holder = accessories.first { $0.view.subviews.contains { $0 === controller.search } }
    #expect(holder != nil)
    #expect(holder?.layoutAttribute == .trailing)
}

@MainActor
@Test func theSearchFieldStillFiltersAndSaysWhenNothingMatches() {
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
