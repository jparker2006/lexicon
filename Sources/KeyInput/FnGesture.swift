import LexiconDomain

/// What the tap thread feeds the recognizer. Built from CGEvents in EventTap.swift.
enum KeyInput: Sendable, Hashable {
    /// `secureInput`: macOS secure event input was on (a password field has focus).
    /// `id`: the Dictation this press starts, if it starts one.
    case fnDown(HostTime, secureInput: Bool, id: DictationID)
    case fnUp(HostTime)
    /// Any other key-down. Modifiers (Shift included) are flag changes, never key-downs,
    /// so they never get here: Shift with fn never cancels (it is the Re-speak trigger in M4).
    case otherKey(HostTime)
    /// Plain Esc. Reported by the tap and, while it is registered, by the Esc
    /// hotkey: the same press can arrive twice, and the second finds nothing to end.
    case escape(HostTime)
    /// A timer the recognizer asked for has fired.
    case deadline(HostTime)
    /// The Mac is going to sleep (see `Keyboard.systemWillSleep`).
    case sleep(HostTime)
}

/// The fn gesture state machine (#53, #58). Pure: no clocks, no threads, no
/// CGEvent. Unit-tested with scripted inputs. Internal to KeyInput.
///
///     idle --fnDown--> pressed                    emits .dictationBegan (recording starts now)
///     idle --fnDown, secure input on--> idle      nothing: a password field is never dictated into
///     pressed --held >= hold threshold--> recording(hold)   emits .dictationConfirmed(.hold)
///     pressed --fnUp before the threshold--> tapped         recording goes on through the gap
///     pressed --other key or Esc before the threshold--> idle   emits .dictationDiscarded (a shortcut like fn+arrow)
///     tapped --fnDown within the double-tap window--> recording(handsFree)   the SAME Dictation, confirmed
///     tapped --anything else, or the window ends--> idle    emits .dictationDiscarded (lone tap: nothing in History)
///     recording(hold) --fnUp--> idle              emits .dictationStopped
///     recording(handsFree) --fnDown--> idle       emits .dictationStopped; its fn-up then lands in idle
///     recording --Esc--> idle                     emits .dictationCancelled (saved, never typed)
///     recording --cap--> idle                     emits .oneMinuteLeft at the warning, .dictationStopped at the cap
///     recording --sleep--> idle                   emits .dictationStopped
///     pressed or tapped --sleep--> idle           judged as a release: a press under the threshold is discarded
///
/// The id on fn-down names the Dictation; every command for that press carries it.
/// A double tap's second press is not a new Dictation: its id is dropped.
///
/// Every input carries the event's own time, and every rule is judged on it,
/// not on when a timer happened to fire: fn-up or a key at 0.31 s still counts
/// as a hold even if the 0.30 s deadline has not been delivered yet.
///
/// Every event passes through the tap. Only Esc is ever taken from the app in
/// front, and only while `takesEscape` (the Esc hotkey follows it).
struct FnGesture: Sendable {
    enum Phase: Sendable, Hashable {
        case idle
        /// fn is down, not yet a hold. Capture is running (fn never waits).
        case pressed(DictationID, since: HostTime)
        /// A short press was released. Capture keeps running through the gap, so a
        /// second fn-down before `releasedAt + doubleTapWindow` makes this same Dictation hands-free.
        case tapped(DictationID, began: HostTime, releasedAt: HostTime)
        /// Confirmed, as a hold or hands-free: the pill shows it, Esc is taken, the cap runs.
        case recording(Recording)
    }

    /// One confirmed Dictation. Hold and hands-free share Esc, the cap, sleep and
    /// other keys; they differ only in what fn-down and fn-up do.
    struct Recording: Sendable, Hashable {
        let id: DictationID
        let mode: DictationMode
        /// fn-down of the press that began capture (the first tap, in hands-free).
        /// The cap counts from here, as the audio does.
        let began: HostTime
        /// The warning went out, so it goes out once however deadlines arrive.
        var warned = false
    }

    struct Output: Sendable, Hashable {
        var commands: [KeyCommand] = []
        /// Ask the driver to deliver `.deadline` at this time.
        var wakeAt: HostTime?
    }

    private(set) var phase: Phase = .idle
    private let config: KeyboardConfig

    init(_ config: KeyboardConfig) {
        self.config = config
    }

    /// Capture is running: any phase but idle.
    var isRecording: Bool { phase != .idle }

    /// Esc is taken from the app in front exactly while this is true: from the
    /// confirmed hold or second tap to the end, so a stray tap never eats Esc.
    var takesEscape: Bool {
        if case .recording = phase { true } else { false }
    }

    mutating func handle(_ input: KeyInput) -> Output {
        switch phase {
        case .idle: idle(input)
        case .pressed(let id, let since): pressed(id, since: since, input)
        case .tapped(let id, let began, let releasedAt): tapped(id, began: began, releasedAt: releasedAt, input)
        case .recording(let recording): whileRecording(recording, input)
        }
    }

    // One function per phase, each an exhaustive switch over KeyInput, so a new
    // input fails the build in every phase until each says what it does.

    private mutating func idle(_ input: KeyInput) -> Output {
        switch input {
        case .fnDown(let at, secureInput: false, let id):
            return begin(id, at: at)
        case .fnDown, .fnUp, .otherKey, .escape, .deadline, .sleep:
            // A password field, the stop press's own fn-up, a key, a stale deadline, a
            // second report of an Esc that already cancelled: nothing to do.
            return Output()
        }
    }

    private mutating func pressed(_ id: DictationID, since: HostTime, _ input: KeyInput) -> Output {
        switch input {
        case .fnDown:
            // Its fn-up was lost (the tap was briefly disabled): the press goes on.
            return Output()
        case .fnUp(let at):
            if isHeld(since, at: at) {
                phase = .idle
                return Output(commands: [.dictationConfirmed(id, .hold), .dictationStopped(id, at: at)])
            }
            phase = .tapped(id, began: since, releasedAt: at)
            return Output(wakeAt: at.advanced(by: config.doubleTapWindow))
        case .otherKey(let at):
            guard isHeld(since, at: at) else { return discard(id) }
            return confirm(id, .hold, began: since)
        case .escape(let at):
            // Under the threshold Esc is a chord like any key, and it reached the app.
            guard isHeld(since, at: at) else { return discard(id) }
            phase = .idle
            return Output(commands: [.dictationConfirmed(id, .hold), .dictationCancelled(id)])
        case .deadline(let now):
            // A timer that fires a hair early asks again rather than leaving the hold unconfirmed.
            guard isHeld(since, at: now) else { return Output(wakeAt: since.advanced(by: config.holdThreshold)) }
            return confirm(id, .hold, began: since)
        case .sleep(let at):
            // Lid close or sleep ends a press the way letting go of fn would; a press
            // under the threshold is a lone tap, discarded, not the start of a double tap.
            guard isHeld(since, at: at) else { return discard(id) }
            phase = .idle
            return Output(commands: [.dictationConfirmed(id, .hold), .dictationStopped(id, at: at)])
        }
    }

    private mutating func tapped(_ id: DictationID, began: HostTime, releasedAt: HostTime, _ input: KeyInput) -> Output {
        let closes = releasedAt.advanced(by: config.doubleTapWindow)
        switch input {
        case .fnDown(let at, let secureInput, _):
            // The second tap. A password field took focus in the gap: never dictate into it.
            guard at > closes else { return secureInput ? discard(id) : confirm(id, .handsFree, began: began) }
            // Late for a double tap (its deadline not yet delivered): the tap was alone,
            // and this press is a new one.
            let alone = discard(id)
            let next = idle(input)
            return Output(commands: alone.commands + next.commands, wakeAt: next.wakeAt)
        case .fnUp:
            return Output()
        case .otherKey, .escape, .sleep:
            // A key between the taps: not a double tap. Esc was never taken, it reached the app.
            return discard(id)
        case .deadline(let now):
            return now >= closes ? discard(id) : Output(wakeAt: closes)
        }
    }

    private mutating func whileRecording(_ recording: Recording, _ input: KeyInput) -> Output {
        let id = recording.id
        switch input {
        case .fnDown(let at, _, _):
            // Hands-free: the next press stops, and its fn-up then lands in idle, so it
            // can never be the first tap of a new double tap. Hold: its fn-up was lost.
            guard recording.mode == .handsFree else { return Output() }
            phase = .idle
            return Output(commands: [.dictationStopped(id, at: at)])
        case .fnUp(let at):
            // Hands-free ignores the starting press's release (and the watchdog's synthetic one).
            guard recording.mode == .hold else { return Output() }
            phase = .idle
            return Output(commands: [.dictationStopped(id, at: at)])
        case .otherKey:
            return Output()  // passed through; recording continues
        case .escape:
            phase = .idle
            return Output(commands: [.dictationCancelled(id)])
        case .deadline(let now):
            return capDeadline(recording, now: now)
        case .sleep(let at):
            phase = .idle
            return Output(commands: [.dictationStopped(id, at: at)])
        }
    }

    // MARK: Steps

    private mutating func begin(_ id: DictationID, at: HostTime) -> Output {
        phase = .pressed(id, since: at)
        return Output(commands: [.dictationBegan(id, at: at)], wakeAt: at.advanced(by: config.holdThreshold))
    }

    private mutating func discard(_ id: DictationID) -> Output {
        phase = .idle
        return Output(commands: [.dictationDiscarded(id)])
    }

    /// Enters `.recording` and asks to wake at the warning.
    private mutating func confirm(_ id: DictationID, _ mode: DictationMode, began: HostTime) -> Output {
        let recording = Recording(id: id, mode: mode, began: began)
        phase = .recording(recording)
        return Output(commands: [.dictationConfirmed(id, mode)], wakeAt: warnAt(recording))
    }

    /// The cap clock: stop at `began + cap`, warn once before it, and always say
    /// when to wake next. An early or stale deadline just asks again.
    private mutating func capDeadline(_ recording: Recording, now: HostTime) -> Output {
        let capAt = recording.began.advanced(by: config.cap)
        if now >= capAt {
            phase = .idle
            return Output(commands: [.dictationStopped(recording.id, at: capAt)])
        }
        guard !recording.warned, now >= warnAt(recording) else {
            return Output(wakeAt: recording.warned ? capAt : warnAt(recording))
        }
        var warned = recording
        warned.warned = true
        phase = .recording(warned)
        return Output(commands: [.oneMinuteLeft(recording.id)], wakeAt: capAt)
    }

    private func warnAt(_ recording: Recording) -> HostTime {
        recording.began.advanced(by: config.cap - config.capWarning)
    }

    private func isHeld(_ since: HostTime, at time: HostTime) -> Bool {
        time >= since.advanced(by: config.holdThreshold)
    }
}

extension HostTime {
    func advanced(by duration: Duration) -> HostTime {
        let (seconds, attoseconds) = duration.components
        return HostTime(nanoseconds: UInt64(Int64(nanoseconds) + seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }
}
