import Testing
import LexiconDomain
import LexiconCore
import LexiconUI

// The pill and the menu bar icon take their state from the Conductor's events
// (#55). Drawing is checked in the live app (`scripts/harness.sh pill`).

private let a = DictationID(), b = DictationID()

/// Feeds the events in order and returns each step's state and sound.
private func follow(_ events: [ConductorEvent]) -> [(IndicatorState, SoundCue?)] {
    var follower = IndicatorFollower()
    return events.map { event in
        let cue = follower.apply(event)
        return (follower.state, cue)
    }
}

private func states(_ events: [ConductorEvent]) -> [IndicatorState] { follow(events).map(\.0) }
private func cues(_ events: [ConductorEvent]) -> [SoundCue] { follow(events).compactMap(\.1) }

@Test func aHeldDictationThatTypesShowsRecordingThenFinishingThenLanded() {
    let events: [ConductorEvent] = [.started(a), .listening(a), .confirmed(a, .hold), .stopped(a), .transcribing(a),
                                    .finished(a, .inserted)]
    #expect(states(events) == [.hidden, .hidden, .recording(.hold, minuteLeft: false), .finishing, .finishing, .landed])
    #expect(cues(events) == [.start, .stop])
}

@Test func nothingShowsOrSoundsBeforeTheHoldIsConfirmed() {
    // fn+arrow and a lone tap start a recording that is discarded before it is confirmed.
    #expect(states([.started(a), .listening(a)]) == [.hidden, .hidden])
    #expect(cues([.started(a), .listening(a)]).isEmpty)
}

@Test func handsFreeShowsTheLockState() {
    #expect(states([.started(a), .confirmed(a, .handsFree)]).last == .recording(.handsFree, minuteLeft: false))
}

@Test func theOneMinuteWarningKeepsTheModeAndSounds() {
    let events: [ConductorEvent] = [.started(a), .confirmed(a, .handsFree), .oneMinuteLeft(a)]
    #expect(states(events).last == .recording(.handsFree, minuteLeft: true))
    #expect(cues(events) == [.start, .warning])
}

@Test func theStopSoundPlaysOnceWhetherStoppedOrTranscribingComesFirst() {
    // A file Dictation has no fn-up: `transcribing` is its first sign of the end.
    #expect(cues([.confirmed(a, .hold), .transcribing(a), .stopped(a)]) == [.start, .stop])
    #expect(cues([.confirmed(a, .hold), .stopped(a), .transcribing(a)]) == [.start, .stop])
}

@Test func textThatWasNotTypedShowsPasteLastWithTheErrorSound() {
    let events: [ConductorEvent] = [.confirmed(a, .hold), .stopped(a), .notice(.readyToPaste(a)),
                                    .finished(a, .notInserted)]
    #expect(states(events).suffix(2) == [.pasteLast, .pasteLast])
    #expect(cues(events) == [.start, .stop, .error])
}

@Test func aDictationWithNoTextShowsAnError() {
    let events: [ConductorEvent] = [.confirmed(a, .hold), .stopped(a), .finished(a, .failed)]
    #expect(states(events).last == .error("No speech heard"))
    #expect(cues(events).last == .error)
}

@Test func aWaitingDictationSaysItIsSaved() {
    let events: [ConductorEvent] = [.confirmed(a, .hold), .stopped(a), .notice(.waitingForNetwork(a)),
                                    .finished(a, .waiting)]
    guard case .error = states(events).last else { Issue.record("expected an error state"); return }
    #expect(cues(events) == [.start, .stop, .error])
}

@Test func anEarlierDictationFinishingNeverCoversTheOneRecording() {
    // fn never waits: B starts while A is still finishing.
    let events: [ConductorEvent] = [.confirmed(a, .hold), .stopped(a), .started(b), .confirmed(b, .hold),
                                    .finished(a, .inserted), .notice(.readyToPaste(a)), .finished(a, .failed)]
    #expect(states(events).last == .recording(.hold, minuteLeft: false))
    #expect(cues(events) == [.start, .stop, .start])
}

@Test func aFileDictationNeverShowsThePill() {
    // The dev app's dictate hook and lexicon-eval never confirm a gesture.
    let events: [ConductorEvent] = [.started(a), .listening(a), .transcribing(a), .finished(a, .inserted)]
    #expect(states(events).allSatisfy { $0 == .hidden })
    #expect(cues(events).isEmpty)
}

@Test func aMicrophoneProblemShowsAnErrorEvenBeforeConfirmation() {
    // The recorder failed at fn-down, so no confirmation will ever come.
    let events: [ConductorEvent] = [.notice(.microphoneUnavailable("no device"))]
    guard case .error(let line) = states(events).last else { Issue.record("expected an error state"); return }
    #expect(!line.contains("no device"))  // raw error text never reaches the UI
    #expect(cues(events) == [.error])
}

@Test func pasteLastWithNothingToPasteSaysSo() {
    guard case .error = states([.notice(.nothingToPaste)]).last else { Issue.record("expected an error state"); return }
    guard case .error = states([.notice(.noFieldToPaste)]).last else { Issue.record("expected an error state"); return }
}
