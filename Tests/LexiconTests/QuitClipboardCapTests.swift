import Foundation
import Testing
@testable import AppText

// Quit's wait for the clipboard restore is capped on the Clock it is given. These
// tests move only that TestClock; the keeper's own FakeClock never moves.

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

/// Quit while the target has read a paste and nothing has settled it: `expire` is
/// never called, so only the 2 s cap can end the wait. The wait must not end
/// before the cap, must end at it, and must give Jake's clipboard back.
@MainActor @Test(.timeLimit(.minutes(1))) func quitWaitsNoLongerThanItsCapAndStillGivesJakesClipboardBack() async {
    let board = FakePasteboard(), clock = FakeClock(), quitClock = TestClock()
    board.jakeCopies("jake's text")
    let keeper = keeper(board, clock)
    _ = keeper.put("dictation")
    _ = board.targetReads()

    var finished = false
    let quit = Task {
        await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
        finished = true
    }
    // Wait until the quit sleeps on the clock or has already returned. Waiting for
    // the sleep alone would hang forever at a quit that returns at once.
    while !finished, quitClock.sleepers != 1, !Task.isCancelled { await Task.yield() }
    #expect(!finished, "quit returned before its 2 s cap passed")

    await quitClock.advance(by: ClipboardKeeper.missedHold)
    await quit.value
    #expect(board.showing == "jake's text")
}

/// Jake copies something while quit waits. When the cap passes, the restore must
/// leave his copy alone, not put his old clipboard over it.
@MainActor @Test(.timeLimit(.minutes(1))) func aQuitCapNeverOverwritesSomethingJakeCopied() async {
    let board = FakePasteboard(), clock = FakeClock(), quitClock = TestClock()
    board.jakeCopies("jake's text")
    let keeper = keeper(board, clock)
    _ = keeper.put("dictation")
    _ = board.targetReads()

    var finished = false
    let quit = Task {
        await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
        finished = true
    }
    while !finished, quitClock.sleepers != 1, !Task.isCancelled { await Task.yield() }
    // The guard: the overwrite check below only means something while the wait is still running.
    #expect(!finished, "quit returned before its 2 s cap passed")

    board.jakeCopies("copied later")
    await quitClock.advance(by: ClipboardKeeper.missedHold)
    await quit.value
    #expect(board.showing == "copied later")
}

/// A paste made after quit began (a Dictation fn started meanwhile) is waited for too,
/// with its own cap from when quit takes it up, so its 2 s hold is never cut short.
@MainActor @Test(.timeLimit(.minutes(1))) func quitWaitsForALaterPasteWithoutCuttingItsHold() async {
    let board = FakePasteboard(), clock = FakeClock(), quitClock = TestClock()
    board.jakeCopies("jake's text")
    let keeper = keeper(board, clock)
    _ = keeper.put("dictation")
    _ = board.targetReads()

    var finished = false
    let quit = Task {
        await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: quitClock)
        finished = true
    }
    await quitClock.waitForSleep(endingAt: ClipboardKeeper.missedHold)  // quit waits on the first paste
    await quitClock.advance(by: .seconds(1))
    _ = keeper.put("later dictation")  // nobody has read it yet: it is in its hold
    // Quit takes the later paste up a second in: its cap ends a hold's length after that.
    while !finished, !Task.isCancelled,
          quitClock.sleepers != 1 || quitClock.now.offset != .seconds(1) { await Task.yield() }
    #expect(!finished, "quit waits for the later paste too")

    await quitClock.advance(by: .seconds(1))
    #expect(board.showing == "later dictation", "the later paste's text is still up for a queued Cmd-V")
    await quitClock.advance(by: .seconds(1))
    await quit.value
    #expect(board.showing == "jake's text")
}
