public import LexiconDomain
public import LexiconCore

/// Turns the Conductor's events into what the pill and the menu bar icon show,
/// and the sound to play. Pure, so the rules are tested without a window.
///
/// The pill follows one Dictation: the newest one confirmed as a hold or
/// hands-free. Nothing shows at fn-down: fn+arrow and a stray tap start a
/// recording too, and they must stay silent. An earlier Dictation still
/// finishing never covers the one recording; its text is safe in History either way.
public struct IndicatorFollower: Sendable {
    public private(set) var state: IndicatorState = .hidden
    private var current: DictationID?
    private var stopSounded = false

    public init() {}

    /// Applies one event and returns the sound it calls for, if any.
    public mutating func apply(_ event: ConductorEvent) -> SoundCue? {
        switch event {
        case .started, .listening:
            return nil
        case .confirmed(let id, let mode):
            let sounds = id != current
            if sounds {
                current = id
                stopSounded = false
            }
            state = .recording(mode, minuteLeft: false)
            return sounds ? .start : nil
        case .oneMinuteLeft(let id):
            guard id == current, case .recording(let mode, _) = state else { return nil }
            state = .recording(mode, minuteLeft: true)
            return .warning
        case .stopped(let id), .transcribing(let id):
            guard id == current, !stopSounded else { return nil }
            stopSounded = true
            state = .finishing
            return .stop
        case .finished(let id, let status):
            guard id == current, !isRecording else { return nil }
            return finish(status)
        case .notice(let notice):
            return show(notice)
        }
    }

    private var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    private mutating func finish(_ status: DictationStatus) -> SoundCue? {
        switch status {
        case .inserted:
            state = .landed
            return nil
        case .failed:
            return fail("No speech heard")
        case .waiting:
            // Not "waiting for the network": a local model that failed waits too.
            return fail("Saved. No text yet")
        case .notInserted, .recovered:
            // A live Dictation that was not typed already showed paste-last (`readyToPaste` comes first).
            if state != .pasteLast { state = .hidden }
            return nil
        case .recording, .transcribing, .ready:
            state = .hidden
            return nil
        }
    }

    /// Exhaustive: a new notice fails the build here until it has its line.
    /// While Jake is talking the pill keeps showing the recording: a notice
    /// then would hide it after a moment with fn still down.
    private mutating func show(_ notice: Notice) -> SoundCue? {
        if isRecording { return nil }
        switch notice {
        case .readyToPaste(let id):
            guard id == current else { return nil }
            state = .pasteLast
            return .error
        case .waitingForNetwork:
            return nil  // `finished(.waiting)` follows and says it
        case .recovered:
            // At launch, with nothing else going on: a line, no sound.
            state = .error("Recovered a Dictation. It's in History")
            return nil
        // These come with no Dictation, or with one that is now useless: say so whatever else is showing.
        case .microphoneUnavailable: return fail("Microphone unavailable")
        case .microphoneSilent: return fail("No sound from the microphone")
        case .microphoneMuted: return fail("Microphone is muted")
        case .diskTrouble: return fail("Can't save audio to disk")
        case .accessibilityNeeded: return fail("Allow Accessibility in the Lexicon menu")
        case .nothingToPaste: return fail("Nothing to paste yet")
        case .noFieldToPaste: return fail("Click a text field, then press \u{2303}\u{2318}V")
        case .fixNotLanded(let problem): return fail(Self.line(for: problem))
        }
    }

    /// One plain sentence per problem. Exhaustive, so a new one fails the build here.
    static func line(for problem: FixProblem) -> String {
        switch problem {
        case .movedOn: "You moved on, so nothing was fixed"
        case .textChanged: "That text changed, so nothing was fixed"
        case .cannotSelect: "This app won't let Lexicon select text. Nothing was fixed"
        case .terminal: "Can't fix text in a terminal or a collapsed paste yet"
        case .noField: "No text field to fix"
        case .clipboardDenied: "Lexicon can't use the clipboard here, so nothing was fixed"
        case .pasteFailed: "The fix didn't paste"
        case .unverified: "Check the fix: Lexicon couldn't see it land"
        case .historyUnreadable: "Fixed, but History couldn't be read to save it"
        case .nothingHeard: "Didn't catch a word, so nothing was fixed"
        case .noSelection: "Select the words to fix, then try again"
        case .tooLate: "The words came too late, so nothing was fixed"
        }
    }

    private mutating func fail(_ line: String) -> SoundCue {
        state = .error(line)
        return .error
    }
}
