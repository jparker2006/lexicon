import Foundation
import Testing
@testable import KeyInput
@testable import Cleanup
@testable import History
import AppText
import LexiconDomain
import AudioCapture
import Transcription
import LexiconCore

// What package tests look like: no mic, no keys, no network, no AX.
// Each body calls a sketch stub, so each test stays disabled until its ticket
// lands; `scripts/check.sh` still compiles every one.

@Test(.disabled("lands with #53")) func holdPastThresholdIsPushToTalk() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300), doubleTapWindow: .milliseconds(250))
    let t0 = HostTime(nanoseconds: 1_000_000_000)
    let down = gesture.handle(.fnDown(t0))
    #expect(down.commands == [.dictationBegan(at: t0)])
    #expect(down.swallow == false)  // fn always passes through
    _ = gesture.handle(.deadline(HostTime(nanoseconds: t0.nanoseconds + 300_000_000)))
    let up = gesture.handle(.fnUp(HostTime(nanoseconds: t0.nanoseconds + 2_000_000_000)))
    #expect(up.commands.contains(.dictationStopped(at: HostTime(nanoseconds: t0.nanoseconds + 2_000_000_000))))
}

@Test(.disabled("lands with #59")) func recoveryPlanIsIdempotent() {
    let id = DictationID()
    let rows = [RecoveryPlan.RowState(id: id, status: .recording, audio: .onDisk)]
    let first = RecoveryPlan.plan(rows: rows, files: [id: .open])
    #expect(first == [.finalize(id), .transcribe(id, wasWaiting: false)])
    // After finalize, the same row plans only the transcription again.
    let second = RecoveryPlan.plan(rows: rows, files: [id: .closed])
    #expect(second == [.transcribe(id, wasWaiting: false)])
}

@Test(.disabled("lands with #42")) func cleanupNeverChangesMeaning() {
    let out = TextPass.run("um so wire the auth callback into super base", rules: RuleSet([Rule(heard: "super base", written: "Supabase")]),
                           app: .unknown)
    #expect(out == "So wire the auth callback into Supabase")
}

@Test(.disabled("lands with #60")) func lateTextIsHeldWhenJakeTypedSinceFnUp() {
    let field = FocusSnapshot(pid: 42, fieldFingerprint: "f1")
    #expect(InsertGuard.decide(target: field, focusNow: field, inputSinceMark: false) == .insert)
    #expect(InsertGuard.decide(target: field, focusNow: field, inputSinceMark: true) == .hold(.typedSince))
    #expect(InsertGuard.decide(target: field, focusNow: FocusSnapshot(pid: 7, fieldFingerprint: "f1"),
                               inputSinceMark: false) == .hold(.focusMoved))
}

@Test(.disabled("lands with #41")) func replayedEventsCannotMoveStatusBackwards() {
    #expect(DictationStatus.notInserted.canMove(to: .inserted))
    #expect(!DictationStatus.inserted.canMove(to: .waiting))       // a late `.waiting` replay is a no-op
    #expect(DictationStatus.inserted.canMove(to: .inserted))       // same-state replay is allowed, changes nothing
    #expect(HistoryStore.admits(.recording, from: nil))
    #expect(!HistoryStore.admits(.transcribing, from: nil))
}

@Test(.disabled("lands with #41")) func unfinishedIndexIsGeneratedFromTheEnum() {
    #expect(HistorySchema.derivedIndexes[0].hasSuffix("('recording', 'transcribing', 'waiting')"))
}

@Test(.disabled("lands with #74")) func structuralCheckRejectsChangedNumbers() {
    let failure = StructuralCheck.check("Ship it on the 5th", ruled: "ship it on the fourth", terms: [])
    #expect(failure == .numberMismatch)
}

@Test(.disabled("lands with #46")) func aWavRunsTheWholeLifecycleHeadless() async throws {
    // 16 kHz mono fixture, ~38 KB for 1.2 s (#14). Real package: a `.copy("Fixtures")` resource.
    let wav = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/hello-lexicon.wav")
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown,
                                         preferences: .defaults, local: nil)
    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    #expect(result.status == .inserted)
    #expect(result.cleanup != nil)
    await system.history.flush()
}
