import Foundation
import Testing
@testable import AppText

// Quit waits for the keeper's own restore, which Paster's timer runs through `expire`,
// and Jake's clipboard is back when quit returns. These tests never move the quit's
// TestClock: a quit that waited for its cap would hang here until the time limit.

/// A pasteboard in memory. `targetReads()` is the paste target asking for the
/// promised text; `jakeCopies` is Jake copying something.
@MainActor private final class FakePasteboard: Clipboard {
    private(set) var changeCount = 0
    private(set) var items: [[PasteboardContents.Entry]] = []
    private var promised: (text: String, onRead: @MainActor () -> Void)?
    private(set) var contentsReads = 0
    var readable = true

    func contents() -> PasteboardContents {
        contentsReads += 1
        return PasteboardContents(items: items)
    }

    func promise(_ text: String, onRead: @escaping @MainActor () -> Void) -> Int {
        changeCount += 1
        items = []
        promised = (text, onRead)
        return changeCount
    }

    func write(_ contents: PasteboardContents) {
        changeCount += 1
        items = contents.items
        promised = nil
    }

    func jakeCopies(_ text: String) {
        write(PasteboardContents(items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]]))
    }

    /// What Cmd-V would paste now.
    func targetReads() -> String? {
        promised?.onRead()
        return showing
    }

    /// What the pasteboard holds, without reading it as a target would.
    var showing: String? {
        promised?.text ?? items.first?.first.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

@MainActor private final class FakeClock {
    let start = ContinuousClock.now
    var now: ContinuousClock.Instant
    init() { now = start }
    func at(_ ms: Int) -> ContinuousClock.Instant {
        now = start + .milliseconds(ms)
        return now
    }
}

@MainActor private func keeper(_ board: FakePasteboard, _ clock: FakeClock) -> ClipboardKeeper {
    ClipboardKeeper(pasteboard: board, now: { clock.now })
}

/// The target read the Dictation at 0 ms, so the restore is due at 200 ms of quiet.
/// Quit starts first and must not return before that restore: when it returns,
/// Jake's clipboard is back.
@MainActor @Test(.timeLimit(.minutes(1))) func quittingDuringAPendingRestoreGivesJakesClipboardBack() async {
    let board = FakePasteboard(), clock = FakeClock(), quitClock = TestClock()
    board.jakeCopies("jake's text")
    let keeper = keeper(board, clock)
    _ = keeper.put("dictation")
    _ = clock.at(0)
    #expect(board.targetReads() == "dictation")

    var started = false
    var showingWhenQuitReturned: String?
    let quit = Task {
        started = true
        await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
        showingWhenQuitReturned = board.showing
    }
    // Wait for quit to begin on its own signal: the restore is still to come.
    while !started { await Task.yield() }
    // Quit must not take the clipboard back itself: a Cmd-V still queued would paste it.
    #expect(board.showing == "dictation")
    _ = keeper.expire(at: clock.at(200))  // Paster's timer: reads went quiet, the restore runs
    await quit.value
    #expect(showingWhenQuitReturned == "jake's text")
}

/// No target read the Dictation, so the text is held for 2 s after the 1 s miss.
/// Quit starts inside that hold and must return only after the restore at 2 s.
@MainActor @Test(.timeLimit(.minutes(1))) func quittingDuringThePostMissHoldGivesJakesClipboardBack() async {
    let board = FakePasteboard(), clock = FakeClock(), quitClock = TestClock()
    board.jakeCopies("jake's text")
    let keeper = keeper(board, clock)
    let paste = keeper.put("dictated")
    #expect(keeper.expire(at: clock.at(1_000)) == .missed(paste))  // no read within 1 s

    var started = false
    var showingWhenQuitReturned: String?
    let quit = Task {
        started = true
        await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
        showingWhenQuitReturned = board.showing
    }
    while !started { await Task.yield() }
    #expect(board.showing == "dictated")  // the hold is still on: quit did not take it down
    _ = keeper.expire(at: clock.at(2_000))  // the hold ends, the restore runs
    await quit.value
    #expect(showingWhenQuitReturned == "jake's text")
}

/// Nothing pending, from a fresh keeper and after a paste already settled: quit
/// returns at once, with Jake's clipboard where it was.
@MainActor @Test(.timeLimit(.minutes(1))) func quittingWithNothingPendingReturnsAtOnce() async {
    let board = FakePasteboard(), clock = FakeClock(), quitClock = TestClock()
    board.jakeCopies("jake's text")
    let keeper = keeper(board, clock)

    await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
    #expect(board.showing == "jake's text")

    let paste = keeper.put("dictated")
    _ = clock.at(0)
    #expect(board.targetReads() == "dictated")
    #expect(keeper.expire(at: clock.at(200)) == .settled(paste))
    await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
    #expect(board.showing == "jake's text")
}
