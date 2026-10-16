import Foundation
import Testing
import History
import LexiconDomain
@testable import LexiconUI

// Closing the History window drops the window's controller, its reader and the
// reader's SQLite connection, so a closed window costs no memory (HistoryWindow.swift,
// #4). These tests open a window over the shared synthetic year, show it transparent
// and never key, close it, and check that nothing still holds the controller or the reader.

/// Weak references to what a window opened. A strong one here would be the thing keeping it alive.
@MainActor
private struct WindowWeakRefs {
    weak var controller: HistoryWindowController?
    weak var reader: HistoryReader?
}

/// Builds, shows and closes one window over `paths`. Every strong reference dies when the pool
/// drains, so the test sees only what outlives the close. No run loop turn is needed: what
/// AppKit finishes later is the window itself, which holds neither.
@MainActor
private func openAndCloseWindow(_ paths: AppPaths) -> WindowWeakRefs {
    return autoreleasepool {
        let reader = HistoryReader(paths: paths)
        let controller = HistoryWindowController(reader: reader, system: nil, pasteboard: .withUniqueName()) {}
        // Transparent and never key: the app is not activated and no focus moves, so the test
        // never takes Jake's focus. The window's own show() would activate the app.
        controller.window?.alphaValue = 0
        controller.window?.orderFrontRegardless()
        controller.window?.displayIfNeeded()
        // NSWindowController.close() runs the window's close synchronously, so the close has
        // finished when it returns. What is left to find is work the close deferred.
        controller.close()
        return WindowWeakRefs(controller: controller, reader: reader)
    }
}

/// Once the close finishes, the controller and its reader are freed: nothing else holds them.
@MainActor @Test func aClosedHistoryWindowFreesItsControllerAndItsReader() async throws {
    let (paths, _) = try await year()
    let closed = openAndCloseWindow(paths)
    #expect(closed.controller == nil)
    #expect(closed.reader == nil)
}

/// A second window, opened fresh after the first closed, frees the same way. Whatever the
/// first left behind must not keep either window, or its reader, alive.
@MainActor @Test func aSecondOpenAndCloseFreesItsControllerAndReaderToo() async throws {
    let (paths, _) = try await year()
    let first = openAndCloseWindow(paths)
    let second = openAndCloseWindow(paths)
    #expect(first.controller == nil)
    #expect(first.reader == nil)
    #expect(second.controller == nil)
    #expect(second.reader == nil)
}
