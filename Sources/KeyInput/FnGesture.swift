import LexiconDomain

/// What the tap thread feeds the recognizer. Built from CGEvents in EventTap.swift.
enum KeyInput: Sendable, Hashable {
    case fnDown(HostTime)
    case fnUp(HostTime)
    /// Any other key-down. Only Esc is ever swallowed (no Fn+Space in v0, #18).
    case otherKey(HostTime, isEscape: Bool)
    /// A timer the recognizer asked for has fired.
    case deadline(HostTime)
    /// The core ended the Dictation (see `Keyboard.endDictation`).
    case externalEnd
}

/// The fn gesture state machine (#6). Pure: no clocks, no threads, no CGEvent.
/// Unit-tested with scripted inputs. Internal to KeyInput.
///
///     idle --fnDown--> pressed(provisional, recording already started)
///     pressed --held >= threshold--> holding            emits .dictationConfirmed(.hold)
///     pressed --fnUp before threshold--> tapped         waits doubleTapWindow (0.25 s after fn-up, #18)
///     tapped --fnDown within window--> handsFree        emits .dictationConfirmed(.handsFree)
///     tapped --window passes--> idle                    emits .dictationDiscarded (lone tap: nothing in History)
///     holding --fnUp--> idle                            emits .dictationStopped
///     handsFree --fnDown--> idle                        emits .dictationStopped (never the first tap of a new double-tap)
///     pressed --otherKey--> idle                        emits .dictationDiscarded (a shortcut like fn+arrow)
///     holding/handsFree --otherKey (not Esc)--> same    passed through; recording continues (#18)
///     holding/handsFree --Esc--> idle                   emits .dictationCancelled (Esc swallowed)
///     any recording phase --20 min--> idle              emits .dictationStopped (cap; warning chime at 19 min)
struct FnGesture: Sendable {
    enum Phase: Sendable, Hashable {
        case idle
        case pressed(since: HostTime)
        case tapped(releasedAt: HostTime)
        case holding
        case handsFree
    }

    struct Output: Sendable {
        var commands: [KeyCommand] = []
        /// Return nil from the tap callback (swallow) instead of passing the event on.
        var swallow = false
        /// Ask the driver to deliver `.deadline` at this time.
        var wakeAt: HostTime?
    }

    private(set) var phase: Phase = .idle
    let holdThreshold: Duration
    let doubleTapWindow: Duration

    init(holdThreshold: Duration, doubleTapWindow: Duration) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    /// True while recording, so Esc and Space are swallowed only then.
    var isRecording: Bool { phase != .idle }

    mutating func handle(_ input: KeyInput) -> Output {
        // TODO: implement the table above. fn is always passed through (never swallowed).
        fatalError("not implemented")
    }
}
