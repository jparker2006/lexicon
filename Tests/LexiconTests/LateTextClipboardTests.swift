import Foundation
import Testing
@testable import AppText
import LexiconDomain

/// A pasteboard in memory, as ClipboardRestoreTests has it (its copy is private there).
/// `showing` is what the pasteboard holds now; nothing reads it as a target would.
@MainActor private final class FakePasteboard: Clipboard {
    private(set) var changeCount = 0
    private(set) var items: [[PasteboardContents.Entry]] = []
    private var promised: (text: String, onRead: @MainActor () -> Void)?
    var readable = true

    func contents() -> PasteboardContents {
        PasteboardContents(items: items)
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

/// The app's lane without the key: `paste` puts the text up through the keeper and
/// counts the Cmd-V it would send. `idle` returns at once, as when nothing is unread.
@MainActor private final class KeeperLane: PasteLane {
    private let keeper: ClipboardKeeper
    private(set) var cmdVs = 0

    init(_ keeper: ClipboardKeeper) { self.keeper = keeper }

    func idle() async {}

    func paste(_ text: String, as kind: PasteKind) async -> PasteAttempt {
        cmdVs += 1
        return .sent(keeper.put(text))
    }
}

private let jakesClipboardText = "Jake's password"
/// Where Jake was at fn-up, and the places he can be by the paste.
private let dictationFocus = FocusSnapshot(pid: 7, fieldFingerprint: "claude#1")
private let otherAppFocus = FocusSnapshot(pid: 9, fieldFingerprint: "notes#4")
private let otherFieldFocus = FocusSnapshot(pid: 7, fieldFingerprint: "claude#2")

/// A Dictation whose guard refuses: the paste is held for `reason` before any Cmd-V,
/// and Jake's clipboard is what it was at fn-up, the same pasteboard change count.
@MainActor private func refusesBeforeCmdV(_ reason: NotInsertedReason, target: FocusSnapshot,
                                          focusNow: FocusSnapshot?, inputSinceMark: Bool,
                                          sinceCapture: Duration = .zero) async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies(jakesClipboardText)
    let keeper = keeper(board, clock)
    keeper.prefetch()  // fn-up reads Jake's clipboard ahead of the paste
    let lane = KeeperLane(keeper)
    let countBefore = board.changeCount

    let result = await PasteOrder.run("dictated", as: .dictation, lane: lane) {
        (InsertGuard.decide(target: target, focusNow: focusNow, inputSinceMark: inputSinceMark, sinceCapture: sinceCapture), ())
    }

    guard case .held(let held) = result else { Issue.record("not held: \(result)"); return }
    #expect(held == reason)
    #expect(lane.cmdVs == 0)
    #expect(board.changeCount == countBefore)
    #expect(board.showing == jakesClipboardText)
}

@MainActor @Test func aFocusMoveToAnotherAppHoldsTheDictationBeforeAnyCmdV() async {
    await refusesBeforeCmdV(.focusMoved, target: dictationFocus, focusNow: otherAppFocus, inputSinceMark: false)
}

@MainActor @Test func anotherFieldInTheSameAppHoldsTheDictationBeforeAnyCmdV() async {
    await refusesBeforeCmdV(.focusMoved, target: dictationFocus, focusNow: otherFieldFocus, inputSinceMark: false)
}

@MainActor @Test func typingSinceFnUpHoldsTheDictationBeforeAnyCmdV() async {
    await refusesBeforeCmdV(.typedSince, target: dictationFocus, focusNow: dictationFocus, inputSinceMark: true)
}

@MainActor @Test func noFieldNowHoldsTheDictationBeforeAnyCmdV() async {
    await refusesBeforeCmdV(.noField, target: dictationFocus, focusNow: nil, inputSinceMark: false)
}

@MainActor @Test func aFieldlessAppFiveSecondsAfterFnUpHoldsTheDictationBeforeAnyCmdV() async {
    let fieldless = FocusSnapshot(pid: 7, fieldFingerprint: nil)
    await refusesBeforeCmdV(.tooLate, target: fieldless, focusNow: fieldless, inputSinceMark: false,
                            sinceCapture: InsertGuard.fieldlessWindow)
}

/// A paste the target never reads: it is a miss at 1 s, and Jake's clipboard is back
/// 2 s after the write, not later, with no real time involved.
@MainActor @Test func aPasteNobodyReadIsBackToJakesClipboardWithin2s() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies(jakesClipboardText)
    let keeper = keeper(board, clock)
    keeper.prefetch()  // fn-up
    let lane = KeeperLane(keeper)

    let written = clock.at(0)
    let result = await PasteOrder.run("dictated", as: .dictation, lane: lane) {
        (InsertGuard.decide(target: dictationFocus, focusNow: dictationFocus, inputSinceMark: false, sinceCapture: .zero), ())
    }
    guard case .sent(let id, _, _) = result else { Issue.record("not sent: \(result)"); return }
    #expect(lane.cmdVs == 1)
    #expect(board.showing == "dictated")

    #expect(keeper.expire(at: clock.at(999)) == nil)
    #expect(keeper.expire(at: clock.at(1_000)) == .missed(id))  // no read within 1 s
    #expect(keeper.deadline == written + ClipboardKeeper.missedHold)
    #expect(board.showing == "dictated")  // a Cmd-V still queued pastes the Dictation, never Jake's clipboard
    #expect(keeper.expire(at: clock.at(1_999)) == nil)
    #expect(board.showing == "dictated")

    #expect(keeper.expire(at: clock.at(2_000)) == .settled(id))
    #expect(board.showing == jakesClipboardText)
}
