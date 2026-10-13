import Foundation
import Testing
@testable import Cleanup
@testable import History
import AppText
import LexiconDomain
import AudioCapture
import Transcription
import LexiconCore

// What package tests look like: no mic, no keys, no network, no AX.
// A test whose body calls a sketch stub stays disabled until its ticket lands;
// `scripts/check.sh` still compiles every one.

@Test func recoveryPlanIsIdempotent() {
    let id = DictationID()
    let rows = [RecoveryPlan.RowState(id: id, status: .recording, audio: .onDisk)]
    let first = RecoveryPlan.plan(rows: rows, files: [id: .open])
    #expect(first == [.finalize(id), .transcribe(id, wasWaiting: false)])
    // After finalize, the same row plans only the transcription again.
    let second = RecoveryPlan.plan(rows: rows, files: [id: .closed])
    #expect(second == [.transcribe(id, wasWaiting: false)])
}

@Test func cleanupAppliesRulesAndDropsFillers() {
    let out = TextPass.run("um so wire the auth callback into super base", rules: RuleSet([Rule(heard: "super base", written: "Supabase")]))
    #expect(out == "Wire the auth callback into Supabase")
}

@Test func lateTextIsHeldWhenJakeTypedSinceFnUp() {
    let field = FocusSnapshot(pid: 42, fieldFingerprint: "f1")
    #expect(InsertGuard.decide(target: field, focusNow: field, inputSinceMark: false) == .insert)
    #expect(InsertGuard.decide(target: field, focusNow: field, inputSinceMark: true) == .hold(.typedSince))
    #expect(InsertGuard.decide(target: field, focusNow: FocusSnapshot(pid: 7, fieldFingerprint: "f1"),
                               inputSinceMark: false) == .hold(.focusMoved))
}

@Test func structuralCheckRejectsChangedNumbers() {
    let failure = StructuralCheck.check("Ship it on the 5th", ruled: "ship it on the fourth", terms: [])
    #expect(failure == .numberMismatch)
}
