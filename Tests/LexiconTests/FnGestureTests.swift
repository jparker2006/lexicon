import Testing
@testable import KeyInput
import LexiconDomain

// The fn gesture rules (#53, M0: hold only), fed scripted inputs on a fake
// clock: every time is milliseconds after an arbitrary fn-down at t0.

private let t0: UInt64 = 5_000_000_000

private func at(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: t0 + UInt64(milliseconds) * 1_000_000)
}

/// Feeds `inputs` in order and returns every command, in order.
private func run(_ inputs: [KeyInput], gesture: inout FnGesture) -> [KeyCommand] {
    inputs.flatMap { gesture.handle($0).commands }
}

private func run(_ inputs: [KeyInput]) -> [KeyCommand] {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    return run(inputs, gesture: &gesture)
}

@Test func fnDownStartsRecordingAtOnceAndAsksForTheHoldDeadline() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    let down = gesture.handle(.fnDown(at(0), secureInput: false))
    #expect(down.commands == [.dictationBegan(at: at(0))])
    #expect(down.wakeAt == at(300))
}

@Test func holdIsPushToTalkAndReleaseStops() {
    #expect(run([.fnDown(at(0), secureInput: false), .deadline(at(300)), .fnUp(at(2_000))])
        == [.dictationBegan(at: at(0)), .dictationConfirmed(.hold), .dictationStopped(at: at(2_000))])
}

@Test func loneTapIsDiscarded() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    #expect(run([.fnDown(at(0), secureInput: false), .fnUp(at(90))], gesture: &gesture)
        == [.dictationBegan(at: at(0)), .dictationDiscarded])
    // The deadline it asked for still fires; it is stale and does nothing.
    #expect(gesture.handle(.deadline(at(300))).commands.isEmpty)
    #expect(gesture.phase == .idle)
}

@Test func keyWithinTheThresholdIsAShortcutAndCancelsSilently() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    // fn+Right arrow: the key cancels, then fn-up and the deadline do nothing.
    #expect(run([.fnDown(at(0), secureInput: false), .otherKey(at(120)), .deadline(at(300)), .fnUp(at(400))],
                gesture: &gesture)
        == [.dictationBegan(at: at(0)), .dictationDiscarded])
    #expect(gesture.phase == .idle)
}

@Test func shiftWithFnNeverCancels() {
    // Shift is a modifier flag change, never a key-down, so the recognizer
    // never sees it: fn+Shift (held before fn or pressed after) is still a hold.
    #expect(run([.fnDown(at(0), secureInput: false), .deadline(at(300)), .fnUp(at(1_500))])
        == [.dictationBegan(at: at(0)), .dictationConfirmed(.hold), .dictationStopped(at: at(1_500))])
    // A key after Shift in the first 0.30 s (fn+Shift+arrow, a selection shortcut) still cancels.
    #expect(run([.fnDown(at(0), secureInput: false), .otherKey(at(200))])
        == [.dictationBegan(at: at(0)), .dictationDiscarded])
}

@Test func keyAfterTheThresholdPassesThroughAndRecordingContinues() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    #expect(run([.fnDown(at(0), secureInput: false), .deadline(at(300)), .otherKey(at(800)), .otherKey(at(900)),
                 .fnUp(at(1_200))], gesture: &gesture)
        == [.dictationBegan(at: at(0)), .dictationConfirmed(.hold), .dictationStopped(at: at(1_200))])
}

@Test(arguments: [(290, false), (299, false), (300, true), (310, true)])
func fnUpAtTheEdge(milliseconds: Int, isHold: Bool) {
    // No deadline delivered yet: the fn-up's own time decides.
    let commands = run([.fnDown(at(0), secureInput: false), .fnUp(at(milliseconds))])
    #expect(commands == (isHold
        ? [.dictationBegan(at: at(0)), .dictationConfirmed(.hold), .dictationStopped(at: at(milliseconds))]
        : [.dictationBegan(at: at(0)), .dictationDiscarded]))
}

@Test(arguments: [(290, false), (299, false), (300, true), (310, true)])
func keyAtTheEdge(milliseconds: Int, isHold: Bool) {
    // A key before the deadline is delivered: the key's own time decides.
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    let commands = run([.fnDown(at(0), secureInput: false), .otherKey(at(milliseconds))], gesture: &gesture)
    #expect(commands == (isHold
        ? [.dictationBegan(at: at(0)), .dictationConfirmed(.hold)]
        : [.dictationBegan(at: at(0)), .dictationDiscarded]))
    #expect(gesture.isRecording == isHold)
}

@Test func earlyDeadlineDoesNotConfirm() {
    // A timer that fires a little early (at 0.29 s) confirms nothing; the hold
    // is confirmed by the next input at or past 0.30 s.
    #expect(run([.fnDown(at(0), secureInput: false), .deadline(at(290)), .deadline(at(310)), .fnUp(at(600))])
        == [.dictationBegan(at: at(0)), .dictationConfirmed(.hold), .dictationStopped(at: at(600))])
}

@Test func fnDownWithSecureInputStartsNothing() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    let down = gesture.handle(.fnDown(at(0), secureInput: true))
    #expect(down == FnGesture.Output())
    #expect(run([.otherKey(at(100)), .deadline(at(300)), .fnUp(at(1_000))], gesture: &gesture).isEmpty)
    #expect(gesture.phase == .idle)
}

@Test func externalEndLeavesRecordingAndTheReleaseThenDoesNothing() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    _ = run([.fnDown(at(0), secureInput: false), .deadline(at(300))], gesture: &gesture)
    #expect(gesture.handle(.externalEnd).commands.isEmpty)
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.fnUp(at(900))).commands.isEmpty)
}

@Test func secondFnDownWhileRecordingIsIgnored() {
    // Its fn-up was lost (the tap was briefly disabled): the next release stops.
    #expect(run([.fnDown(at(0), secureInput: false), .deadline(at(300)), .fnDown(at(700), secureInput: false),
                 .fnUp(at(900))])
        == [.dictationBegan(at: at(0)), .dictationConfirmed(.hold), .dictationStopped(at: at(900))])
}

@Test func backToBackDictationsEachStartFresh() {
    #expect(run([.fnDown(at(0), secureInput: false), .fnUp(at(100)),
                 .fnDown(at(400), secureInput: false), .deadline(at(700)), .fnUp(at(1_000))])
        == [.dictationBegan(at: at(0)), .dictationDiscarded,
            .dictationBegan(at: at(400)), .dictationConfirmed(.hold), .dictationStopped(at: at(1_000))])
}
