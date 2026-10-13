import Foundation
import Testing
@testable import AppText

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

@MainActor @Test func jakesClipboardIsBack200msAfterTheTargetsLastRead() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's link")
    let keeper = keeper(board, clock)

    let paste = keeper.put("hello from Lexicon")
    _ = clock.at(30)
    #expect(board.targetReads() == "hello from Lexicon")
    #expect(await keeper.receipt(paste))
    _ = clock.at(120)
    _ = board.targetReads()  // Chromium probes, then reads

    #expect(keeper.expire(at: clock.at(319)) == nil)
    #expect(board.showing == "hello from Lexicon")
    #expect(keeper.expire(at: clock.at(320)) == .settled(paste))
    #expect(board.targetReads() == "Jake's link")
    #expect(keeper.deadline == nil)
}

@MainActor @Test func aCopyJakeMakesAfterThePasteIsNeverOverwritten() {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("old")
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    _ = clock.at(10)
    _ = board.targetReads()
    board.jakeCopies("new copy")

    #expect(keeper.expire(at: clock.at(210)) == .settled(paste))
    #expect(board.targetReads() == "new copy")
}

@MainActor @Test func aTargetThatKeepsReadingGetsTheClipboardBackAt8s() {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's")
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    for ms in stride(from: 10, to: 8_000, by: 150) {
        _ = clock.at(ms)
        _ = board.targetReads()
        #expect(keeper.expire(at: clock.now) == nil)
    }
    #expect(keeper.expire(at: clock.at(8_000)) == .settled(paste))
    #expect(board.targetReads() == "Jake's")
}

@MainActor @Test func noReadWithin1sIsAMissAndJakesClipboardIsBackAt2s() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's password")
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    let receipt = Task { await keeper.receipt(paste) }
    #expect(keeper.expire(at: clock.at(999)) == nil)
    #expect(keeper.expire(at: clock.at(1_000)) == .missed(paste))
    #expect(await receipt.value == false)
    // A target that gets to its Cmd-V a little late pastes the Dictation, never Jake's clipboard.
    #expect(board.showing == "dictated")
    #expect(keeper.expire(at: clock.at(1_999)) == nil)
    #expect(keeper.expire(at: clock.at(2_000)) == .settled(paste))
    #expect(board.showing == "Jake's password")
    #expect(await keeper.receipt(paste) == false)
}

@MainActor @Test func aReadAfterAMissStaysAMissAndTheClipboardIsBack200msLater() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's")
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    #expect(keeper.expire(at: clock.at(1_000)) == .missed(paste))
    _ = clock.at(1_500)
    #expect(board.targetReads() == "dictated")
    #expect(await keeper.receipt(paste) == false)  // History was already told; it is not changed
    #expect(keeper.expire(at: clock.at(1_699)) == nil)
    #expect(keeper.expire(at: clock.at(1_700)) == .settled(paste))
    #expect(board.showing == "Jake's")
}

@MainActor @Test func newTextWaitsUntilTheLastPasteWasRead() async {
    let board = FakePasteboard(), clock = FakeClock()
    let keeper = keeper(board, clock)

    let paste = keeper.put("first")
    #expect(!keeper.isReleased(paste))
    let released = Task { await keeper.released(paste) }
    _ = board.targetReads()
    await released.value
    #expect(keeper.isReleased(paste))
}

@MainActor @Test func aMissedPasteIsReleasedOnlyWhenItSettles() async {
    let board = FakePasteboard(), clock = FakeClock()
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    #expect(keeper.expire(at: clock.at(1_000)) == .missed(paste))
    #expect(!keeper.isReleased(paste))  // its Cmd-V may still be queued
    let released = Task { await keeper.released(paste) }
    #expect(keeper.expire(at: clock.at(2_000)) == .settled(paste))
    await released.value
    #expect(keeper.isReleased(paste))
}

@MainActor @Test func withAccessDeniedADictationIsNotPastedButPasteLastIsWithoutARestore() {
    let board = FakePasteboard(), clock = FakeClock()
    let keeper = keeper(board, clock)
    #expect(keeper.plan(for: .dictation) == .restore)
    #expect(keeper.plan(for: .pasteLast) == .restore)
    board.readable = false  // Jake denied "Paste from Other Apps"
    #expect(keeper.plan(for: .dictation) == nil)
    #expect(keeper.plan(for: .pasteLast) == .keep)  // he asked for it
}

@MainActor @Test func aPasteThatKeepsTheClipboardNeverReadsOrRestoresIt() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("unreadable to Lexicon")
    board.readable = false
    let keeper = keeper(board, clock)

    let paste = keeper.put("newest Dictation", restoring: false)
    _ = clock.at(20)
    #expect(board.targetReads() == "newest Dictation")
    #expect(await keeper.receipt(paste))
    #expect(keeper.expire(at: clock.at(220)) == .settled(paste))
    #expect(board.showing == "newest Dictation")
    #expect(board.contentsReads == 0)
}

@MainActor @Test func aReadAheadNoPasteUsedIsDroppedAfter30s() {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("a big image")
    let keeper = keeper(board, clock)

    keeper.prefetch()
    #expect(keeper.expire(at: clock.at(29_999)) == nil)
    #expect(keeper.deadline == clock.start + .seconds(30))
    #expect(keeper.expire(at: clock.at(30_000)) == nil)
    #expect(keeper.deadline == nil)  // nothing held
    _ = keeper.put("dictated")
    #expect(board.contentsReads == 2)  // read again for this paste
}

@MainActor @Test func backToBackPastesStillRestoreTheClipboardFromBeforeTheFirst() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's")
    let keeper = keeper(board, clock)

    let first = keeper.put("first Dictation")
    _ = clock.at(10)
    #expect(board.targetReads() == "first Dictation")
    _ = clock.at(100)
    keeper.prefetch()  // the second Dictation's fn-up: the pasteboard holds our text, not Jake's
    let second = keeper.put("second Dictation")
    #expect(await keeper.receipt(first))
    _ = clock.at(120)
    #expect(board.targetReads() == "second Dictation")

    #expect(keeper.expire(at: clock.at(320)) == .settled(second))
    #expect(board.targetReads() == "Jake's")
}

@MainActor @Test func anEmptyClipboardIsEmptyAgainAfterThePaste() {
    let board = FakePasteboard(), clock = FakeClock()
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    _ = board.targetReads()
    #expect(keeper.expire(at: clock.at(200)) == .settled(paste))
    #expect(board.items.isEmpty)
    #expect(board.targetReads() == nil)
}

@MainActor @Test func jakesClipboardIsReadAheadAtFnUpAndOnlyOnce() {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's")
    let keeper = keeper(board, clock)

    keeper.prefetch()
    keeper.prefetch()
    #expect(board.contentsReads == 1)
    _ = keeper.put("dictated")
    #expect(board.contentsReads == 1)
}

@MainActor @Test func aCopyBetweenFnUpAndThePasteIsTheOneRestored() {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("before")
    let keeper = keeper(board, clock)

    keeper.prefetch()
    board.jakeCopies("during")
    let paste = keeper.put("dictated")
    _ = board.targetReads()
    #expect(keeper.expire(at: clock.at(200)) == .settled(paste))
    #expect(board.targetReads() == "during")
}

/// The real promise on a private pasteboard (never the general one): a read
/// answers with the text and is the receipt, the markers are there, and every
/// type of every item comes back.
@MainActor @Test func theSystemPasteboardPromisesTheTextAndPutsEveryTypeBack() async {
    let board = SystemPasteboard.scratch()
    board.write(PasteboardContents(items: [
        [.init(type: "public.utf8-plain-text", data: Data("Jake's note".utf8)),
         .init(type: "public.rtf", data: Data("{\\rtf1 Jake's note}".utf8))],
        [.init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))],
    ]))
    let before = board.contents()  // macOS adds types derived from the plain text
    #expect(before.items.count == 2)

    let keeper = ClipboardKeeper(pasteboard: board)
    let paste = keeper.put("dictated text")
    #expect(Set(board.types).isSuperset(of: SystemPasteboard.markers))
    #expect(board.string == "dictated text")
    #expect(await keeper.receipt(paste))

    #expect(keeper.expire(at: .now + .seconds(9)) == .settled(paste))
    #expect(board.contents() == before)
    #expect(board.string == "Jake's note")
}

// MARK: Quit gives Jake's clipboard back (#132)

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

/// No target read the Dictation: it missed at 1 s and its text is held until 2 s after the write.
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
    await quitClock.waitForSleep(endingAt: .seconds(3))
    #expect(!finished, "quit waits for the later paste too")

    await quitClock.advance(by: .seconds(1))
    #expect(board.showing == "later dictation", "the later paste's text is still up for a queued Cmd-V")
    await quitClock.advance(by: .seconds(1))
    await quit.value
    #expect(board.showing == "jake's text")
}
