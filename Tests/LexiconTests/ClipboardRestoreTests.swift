import AppKit
import Testing
@testable import AppText

/// A pasteboard in memory. `targetReads()` is the paste target asking for the
/// promised text; `jakeCopies` is Jake copying something.
@MainActor private final class FakePasteboard: Clipboard {
    private(set) var changeCount = 0
    private(set) var items: [[PasteboardContents.Entry]] = []
    private var promised: (text: String, onRead: @MainActor () -> Void)?
    private(set) var contentsReads = 0

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

@MainActor @Test func noReadWithin1sIsAMissAndTheTextIsWithdrawn() async {
    let board = FakePasteboard(), clock = FakeClock()
    board.jakeCopies("Jake's")
    let keeper = keeper(board, clock)

    let paste = keeper.put("dictated")
    let receipt = Task { await keeper.receipt(paste) }
    #expect(keeper.expire(at: clock.at(999)) == nil)
    #expect(keeper.expire(at: clock.at(1_000)) == .missed(paste))
    #expect(await receipt.value == false)
    // A target that finally gets to Cmd-V gets Jake's clipboard, never text History calls not inserted.
    #expect(board.targetReads() == "Jake's")
    #expect(await keeper.receipt(paste) == false)
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
    let board = NSPasteboard(name: .init("lexicon.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.clearContents()
    let rich = NSPasteboardItem()
    rich.setString("Jake's note", forType: .string)
    rich.setData(Data("{\\rtf1 Jake's note}".utf8), forType: .rtf)
    let image = NSPasteboardItem()
    image.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    board.writeObjects([rich, image])
    let before = SystemPasteboard(board).contents()

    let keeper = ClipboardKeeper(pasteboard: SystemPasteboard(board))
    let paste = keeper.put("dictated text")
    #expect(Set(board.types ?? []).isSuperset(of: SystemPasteboard.markers))
    #expect(board.string(forType: .string) == "dictated text")
    #expect(await keeper.receipt(paste))

    #expect(keeper.expire(at: .now + .seconds(9)) == .settled(paste))
    #expect(SystemPasteboard(board).contents() == before)
    #expect(board.string(forType: .string) == "Jake's note")
}
