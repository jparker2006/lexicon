import Testing
@testable import AppText
import LexiconDomain

/// A lane whose earlier paste stays unread until the test says so.
private actor SlowLane: PasteLane {
    private var unread = true
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var pasted: [String] = []

    func idle() async {
        if unread { await withCheckedContinuation { waiting.append($0) } }
    }

    func paste(_ text: String, as kind: PasteKind) -> PasteAttempt {
        pasted.append(text)
        return .sent(ClipboardKeeper.PasteID(value: pasted.count))
    }

    var isWaiting: Bool { !waiting.isEmpty }

    /// The earlier paste was read (or settled).
    func release() {
        unread = false
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}

/// Focus as the check sees it, changed by the test while the paste waits.
private actor Desk {
    var focus = FocusSnapshot(pid: 7, fieldFingerprint: "claude#1")
    func move(to snapshot: FocusSnapshot) { focus = snapshot }

    func insert(_ text: String, lane: SlowLane, target: FocusSnapshot) async -> PasteOrder.Result<FocusSnapshot> {
        await PasteOrder.run(text, as: .dictation, lane: lane) {
            (InsertGuard.decide(target: target, focusNow: focus, inputSinceMark: false), focus)
        }
    }
}

@Test func focusThatMovesWhileAnEarlierPasteIsUnreadGetsNoPaste() async {
    let lane = SlowLane(), desk = Desk()
    let fnUp = await desk.focus

    let insert = Task { await desk.insert("dictated", lane: lane, target: fnUp) }
    while await !lane.isWaiting { await Task.yield() }  // stuck behind the earlier paste
    await desk.move(to: FocusSnapshot(pid: 9, fieldFingerprint: "notes#4"))  // Jake clicks into Notes
    await lane.release()

    guard case .held(.focusMoved) = await insert.value else { Issue.record("pasted after focus moved"); return }
    #expect(await lane.pasted.isEmpty)
}

@Test func withNothingUnreadThePasteGoesStraightOut() async {
    let lane = SlowLane(), desk = Desk()
    await lane.release()

    let result = await desk.insert("dictated", lane: lane, target: await desk.focus)

    guard case .sent = result else { Issue.record("not sent: \(result)"); return }
    #expect(await lane.pasted == ["dictated"])
}

/// A lane on a Mac where Jake denied Lexicon "Paste from Other Apps".
private struct DeniedLane: PasteLane {
    func idle() async {}
    func paste(_ text: String, as kind: PasteKind) -> PasteAttempt { .denied }
}

@Test func withClipboardAccessDeniedNothingIsPastedAndTheDictationWaitsForPasteLast() async {
    let desk = Desk()
    let fnUp = await desk.focus
    let result = await PasteOrder.run("dictated", as: .dictation, lane: DeniedLane()) {
        (InsertGuard.decide(target: fnUp, focusNow: fnUp, inputSinceMark: false), ())
    }
    guard case .held(.clipboardDenied) = result else { Issue.record("not held: \(result)"); return }
}
