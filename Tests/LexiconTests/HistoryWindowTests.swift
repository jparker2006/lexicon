import AppKit
import Foundation
import Testing
@testable import History
@testable import LexiconUI
import LexiconDomain

// The History window's controller on a throwaway data folder, never put on
// screen and never touching the real clipboard: a private pasteboard stands in.
// What only the running app can show (the menu bar item, focus, first rows on
// screen) is checked in the live-app lane.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let parakeet = SpeechModel.local(.parakeetUnified)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: nil, deviceName: "Mic", storage: .onDisk, gaps: [])

private func dictate(_ store: HistoryStore, _ text: String, at start: Date) {
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: text, cleaned: text), cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    store.record(.delivered(id, InsertionReceipt(appBundleID: app.bundleID, fieldFingerprint: nil, caretAfter: nil,
                                                 contextBefore: "", contextAfter: "", insertedAt: start),
                            lag: .milliseconds(420)))
}

/// A History with `texts` dictated a minute apart this morning, oldest first.
private func history(_ texts: [String]) async throws -> AppPaths {
    let paths = AppPaths.temporary()
    let store = try HistoryStore(paths: paths)
    let morning = Calendar.current.startOfDay(for: Date()).addingTimeInterval(6 * 3_600)
    for (minute, text) in texts.enumerated() { dictate(store, text, at: morning.addingTimeInterval(Double(minute) * 60)) }
    await store.flush()
    return paths
}

@MainActor
private func window(_ paths: AppPaths, pasteboard: NSPasteboard, onClose: @escaping @MainActor () -> Void = {})
    throws -> HistoryWindowController {
    _ = NSApplication.shared
    let controller = HistoryWindowController(reader: try HistoryReader(paths: paths), pasteboard: pasteboard, onClose: onClose)
    controller.window?.layoutIfNeeded()
    return controller
}

@MainActor
private func cell(_ controller: HistoryWindowController, row: Int) -> RowCell? {
    controller.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? RowCell
}

@MainActor @Test func rowsSitUnderTheirDayHeaderNewestFirst() async throws {
    let paths = try await history(["First thing.", "Second thing."])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let controller = try window(paths, pasteboard: pasteboard)

    #expect(controller.table.numberOfRows == 3)
    #expect(controller.tableView(controller.table, isGroupRow: 0))
    #expect((controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? HeaderCell)?.label.stringValue == "Today")
    #expect(cell(controller, row: 1)?.text.stringValue == "Second thing.")
    #expect(cell(controller, row: 2)?.text.stringValue == "First thing.")
    #expect(cell(controller, row: 1)?.details.stringValue == "Parakeet (on this Mac) · 420 ms")
}

@MainActor @Test func clickingARowCopiesItsFinalTextAndFlashesCopied() async throws {
    let paths = try await history(["Wire the auth callback into Supabase.", "Ship it after the tests pass."])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let controller = try window(paths, pasteboard: pasteboard)
    let older = try #require(cell(controller, row: 2))
    #expect(older.copied.isHidden)

    controller.copy(row: 2)
    #expect(pasteboard.string(forType: .string) == "Wire the auth callback into Supabase.")
    #expect(!older.copied.isHidden)

    // A day header copies nothing.
    controller.copy(row: 0)
    #expect(pasteboard.string(forType: .string) == "Wire the auth callback into Supabase.")
}

@MainActor @Test func searchShowsOnlyMatchingRows() async throws {
    let paths = try await history(["Move the Supabase keys.", "Rename it to snake_case.", "Supabase again."])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let controller = try window(paths, pasteboard: pasteboard)

    controller.search.searchField.stringValue = "supabase"
    controller.searched(controller.search.searchField)
    #expect(controller.table.numberOfRows == 3)
    #expect(cell(controller, row: 1)?.text.stringValue == "Supabase again.")
    #expect(cell(controller, row: 2)?.text.stringValue == "Move the Supabase keys.")
    #expect(controller.empty.isHidden)

    controller.search.searchField.stringValue = "nothing like this"
    controller.searched(controller.search.searchField)
    #expect(controller.table.numberOfRows == 0)
    #expect(!controller.empty.isHidden)
    #expect(controller.empty.stringValue == "No matches")
}

@MainActor @Test func longTextWrapsAndIsNeverCutOff() async throws {
    let long = String(repeating: "Every word of a long hands-free Dictation stays visible in History. ", count: 12)
    let paths = try await history([long])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let controller = try window(paths, pasteboard: pasteboard)
    let row = try #require(cell(controller, row: 1))
    controller.window?.layoutIfNeeded()

    let width = row.text.frame.width
    let needed = try #require(row.text.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
    #expect(width > 0)
    #expect(row.text.stringValue == long)
    #expect(needed > 3 * (row.text.font?.boundingRectForFont.height ?? 0))
    #expect(row.text.frame.height >= needed)
    #expect(controller.table.rect(ofRow: 1).height >= needed)
}

@MainActor @Test func closingTheWindowFreesItAndItsReader() async throws {
    let paths = try await history(["Close me."])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    weak var controllerLeft: HistoryWindowController?
    weak var windowLeft: NSWindow?
    weak var readerLeft: HistoryReader?
    var closed = false

    try autoreleasepool {
        let controller = try window(paths, pasteboard: pasteboard) { closed = true }
        controllerLeft = controller
        windowLeft = controller.window
        readerLeft = controller.reader
        _ = cell(controller, row: 1)
        controller.copy(row: 1)
        controller.close()
    }
    #expect(closed)
    #expect(controllerLeft == nil)
    #expect(windowLeft == nil)
    #expect(readerLeft == nil)
}

@MainActor @Test func dayHeadersSayTodayAndYesterdayAndAddTheYearOnlyWhenItDiffers() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 0, minute: 30)))
    func title(_ year: Int, _ month: Int, _ day: Int) -> String {
        HistoryWindowController.title(for: DateComponents(year: year, month: month, day: day), now: now, calendar: calendar)
    }
    #expect(title(2026, 10, 11) == "Today")
    #expect(title(2026, 10, 10) == "Yesterday")
    #expect(title(2026, 10, 9).contains("9"))
    #expect(!title(2026, 10, 9).contains("2026"))
    #expect(title(2025, 10, 9).contains("2025"))
}

@MainActor @Test func theGreyLineShowsModelLagAndAnyStatusWorthAWord() {
    func row(_ status: DictationStatus, cleanup: CleanupOutcome? = .rulesOnly(.off), model: SpeechModel? = parakeet,
             lag: Duration? = .milliseconds(612)) -> HistoryRow {
        HistoryRow(id: DictationID(), startedAt: Date(), finalText: "Text.", status: status, cleanup: cleanup, model: model,
                   lag: lag, pinned: false, hasAudio: true)
    }
    #expect(HistoryWindowController.details(row(.inserted)) == "Parakeet (on this Mac) · 612 ms")
    #expect(HistoryWindowController.details(row(.notInserted, lag: nil)) == "Parakeet (on this Mac) · not inserted")
    #expect(HistoryWindowController.details(row(.recovered, cleanup: .rulesOnly(.rejected(.droppedContentWord)), lag: nil))
        == "Parakeet (on this Mac) · recovered · cleanup rejected")
    #expect(HistoryWindowController.details(row(.waiting, cleanup: nil, model: nil, lag: nil)) == "waiting")
    #expect(HistoryWindowController.details(row(.failed, cleanup: nil, model: nil, lag: nil)) == "failed")
}
