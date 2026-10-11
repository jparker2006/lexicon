import Testing
@testable import KeyInput
import LexiconDomain

// The fn gesture rules (#53, M0: hold only), fed scripted inputs on a fake
// clock: every time is milliseconds after an arbitrary fn-down at t0.

private let t0: UInt64 = 5_000_000_000

/// The Dictations the presses below start, in order.
private let a = DictationID(), b = DictationID()

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
    let down = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    #expect(down.commands == [.dictationBegan(a, at: at(0))])
    #expect(down.wakeAt == at(300))
}

@Test func holdIsPushToTalkAndReleaseStops() {
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .fnUp(at(2_000))])
        == [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .dictationStopped(a, at: at(2_000))])
}

@Test func loneTapIsDiscarded() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90))], gesture: &gesture)
        == [.dictationBegan(a, at: at(0)), .dictationDiscarded(a)])
    // The deadline it asked for still fires; it is stale and does nothing.
    #expect(gesture.handle(.deadline(at(300))).commands.isEmpty)
    #expect(gesture.phase == .idle)
}

@Test func keyWithinTheThresholdIsAShortcutAndCancelsSilently() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    // fn+Right arrow: the key cancels, then fn-up and the deadline do nothing.
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .otherKey(at(120)), .deadline(at(300)), .fnUp(at(400))],
                gesture: &gesture)
        == [.dictationBegan(a, at: at(0)), .dictationDiscarded(a)])
    #expect(gesture.phase == .idle)
}

@Test func keyAfterTheThresholdPassesThroughAndRecordingContinues() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .otherKey(at(800)), .otherKey(at(900)),
                 .fnUp(at(1_200))], gesture: &gesture)
        == [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .dictationStopped(a, at: at(1_200))])
}

@Test(arguments: [(290, false), (299, false), (300, true), (310, true)])
func fnUpAtTheEdge(milliseconds: Int, isHold: Bool) {
    // No deadline delivered yet: the fn-up's own time decides.
    let commands = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(milliseconds))])
    #expect(commands == (isHold
        ? [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .dictationStopped(a, at: at(milliseconds))]
        : [.dictationBegan(a, at: at(0)), .dictationDiscarded(a)]))
}

@Test(arguments: [(290, false), (299, false), (300, true), (310, true)])
func keyAtTheEdge(milliseconds: Int, isHold: Bool) {
    // A key before the deadline is delivered: the key's own time decides.
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    let commands = run([.fnDown(at(0), secureInput: false, id: a), .otherKey(at(milliseconds))], gesture: &gesture)
    #expect(commands == (isHold
        ? [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold)]
        : [.dictationBegan(a, at: at(0)), .dictationDiscarded(a)]))
    #expect(gesture.isRecording == isHold)
}

@Test func earlyDeadlineAsksAgainInsteadOfConfirming() {
    // A timer that fires a little early (at 0.29 s, or on wake from sleep) confirms
    // nothing and asks for the deadline again, so the hold is still confirmed at 0.30 s.
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    #expect(gesture.handle(.deadline(at(290))) == FnGesture.Output(wakeAt: at(300)))
    #expect(gesture.handle(.deadline(at(300))).commands == [.dictationConfirmed(a, .hold)])
    #expect(gesture.handle(.fnUp(at(600))).commands == [.dictationStopped(a, at: at(600))])
}

@Test func fnDownWithSecureInputStartsNothing() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    let down = gesture.handle(.fnDown(at(0), secureInput: true, id: a))
    #expect(down == FnGesture.Output())
    #expect(run([.otherKey(at(100)), .deadline(at(300)), .fnUp(at(1_000))], gesture: &gesture).isEmpty)
    #expect(gesture.phase == .idle)
}

@Test func sleepStopsAHoldAndTheReleaseThenDoesNothing() {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    #expect(gesture.handle(.sleep(at(800))).commands == [.dictationStopped(a, at: at(800))])
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.fnUp(at(900))).commands.isEmpty)
}

@Test func sleepDuringAPressJudgesItLikeARelease() {
    // Held long enough: a Dictation, stopped. Too short: a tap, discarded.
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .sleep(at(500))])
        == [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .dictationStopped(a, at: at(500))])
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .sleep(at(100))])
        == [.dictationBegan(a, at: at(0)), .dictationDiscarded(a)])
}

@Test func sleepWhileIdleDoesNothing() {
    #expect(run([.sleep(at(0)), .fnUp(at(100))]).isEmpty)
}

@Test func secondFnDownWhileRecordingIsIgnored() {
    // Its fn-up was lost (the tap was briefly disabled): the next release stops.
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .fnDown(at(700), secureInput: false, id: b),
                 .fnUp(at(900))])
        == [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .dictationStopped(a, at: at(900))])
}

@Test func backToBackDictationsEachStartFresh() {
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(100)),
                 .fnDown(at(400), secureInput: false, id: b), .deadline(at(700)), .fnUp(at(1_000))])
        == [.dictationBegan(a, at: at(0)), .dictationDiscarded(a),
            .dictationBegan(b, at: at(400)), .dictationConfirmed(b, .hold), .dictationStopped(b, at: at(1_000))])
}

@Test func onlyDoNothingLeavesTheGlobeKeyQuiet() {
    #expect(!GlobeKey.hasSystemAction(usageType: 0))
    for usage in [1, 2, 3] { #expect(GlobeKey.hasSystemAction(usageType: usage)) }
    #expect(GlobeKey.hasSystemAction(usageType: nil))  // unset: the macOS default shows the emoji viewer
}
