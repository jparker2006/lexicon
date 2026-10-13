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
    /// hotkey: the same press can arrive twice. The second finds nothing to end,
    /// or a newer press that began after its stamp, which it leaves alone.
    case escape(HostTime)
    /// A timer the recognizer asked for has fired.
    case deadline(HostTime)
    /// The Mac is going to sleep (see `Keyboard.systemWillSleep`).
    case sleep(HostTime)
    /// The Conductor ended this Dictation itself (see `Keyboard.dictationEnded`).
    case ended(DictationID)
}

/// The fn gesture state machine. Pure: no clocks, no threads, no CGEvent.
/// Unit-tested with scripted inputs. Internal to KeyInput.
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
///     any --Esc stamped before this Dictation began--> same  nothing: the second report of an Esc that ended the last one
///     recording --cap--> idle                     emits .oneMinuteLeft at the warning, .dictationStopped at the cap
///                                                 (a key stamped past a mark gets that mark first, in either order)
///     recording --sleep--> idle                   emits .dictationStopped
///     pressed or tapped --sleep--> idle           judged as a release: a press under the threshold is discarded
///     any --ended, same Dictation--> idle         nothing: the Conductor already ended it
///
/// The id on fn-down names the Dictation; every command for that press carries it.
/// A double tap's second press is not a new Dictation: its id is dropped.
///
/// Every input carries the event's own time, and every rule is judged on it,
/// not on when a timer happened to fire: fn-up or a key at 0.31 s still counts
/// as a hold even if the 0.30 s deadline has not been delivered yet. Keys and
/// timers share the tap thread, so a key stamped before a mark can be handled
/// after the mark's timer. Every mark (the double-tap window, the warning and
/// the cap) acts `lateKeyGrace` after its time (5 ms more when its timer runs
/// late, `EventTapThread.fired`), and the cap's stop is still
/// stamped at the cap. A key is judged against a mark by its own stamp, so it
/// gets one outcome whatever the handling order, unless it is handled more
/// than `lateKeyGrace` after its stamp. Past that
/// bound, the cap remembers when it stopped, so a stop press stamped before it
/// is not a new press.
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
    /// When the cap last stopped a Dictation. An fn-down stamped before it was that
    /// Dictation's stop press, handled after the cap's timer.
    private var cappedAt: HostTime?

    /// How late a key may be handled after its own time and still count against the
    /// double-tap window, the warning and the cap. Keys reached the focused app 2 to
    /// 12 ms after they were pressed through this listen-only tap (ADR 0004); one
    /// handled later than this, behind a stalled tap thread, comes after the mark.
    /// The cost: a dropped tap, the warning sound and the cap's stop each come 50 ms
    /// after their mark, and Quit waits at most this long past the cap for a lost
    /// fn-up (Jake took that trade, DECISIONS.md item 79). After a tap-thread stall,
    /// a late timer waits 5 ms more for the keys queued behind it (item 90,
    /// `EventTapThread.fired`).
    static let lateKeyGrace: Duration = .milliseconds(50)

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
            if let cappedAt, at < cappedAt { return Output() }  // the stop press of a Dictation the cap ended
            return begin(id, at: at)
        case .fnDown, .fnUp, .otherKey, .escape, .deadline, .sleep, .ended:
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
        case .ended(let ended):
            return forget(id, ifItIs: ended)
        case .fnUp(let at):
            if isHeld(since, at: at) {
                phase = .idle
                return Output(commands: [.dictationConfirmed(id, .hold), .dictationStopped(id, at: at)])
            }
            phase = .tapped(id, began: since, releasedAt: at)
            return Output(wakeAt: at.advanced(by: config.doubleTapWindow + Self.lateKeyGrace))
        case .otherKey(let at):
            guard isHeld(since, at: at) else { return discard(id) }
            return confirm(id, .hold, began: since)
        case .escape(let at):
            // Stamped before this press: the other report of an Esc that ended the last one.
            guard at >= since else { return Output() }
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
        case .ended(let ended):
            return forget(id, ifItIs: ended)
        case .escape(let at) where at < began:
            return Output()  // the other report of an Esc that ended the last Dictation
        case .otherKey, .escape, .sleep:
            // A key between the taps: not a double tap. Esc was never taken, it reached the app.
            return discard(id)
        case .deadline(let now):
            let drop = closes.advanced(by: Self.lateKeyGrace)
            return now >= drop ? discard(id) : Output(wakeAt: drop)
        }
    }

    private mutating func whileRecording(_ recording: Recording, _ input: KeyInput) -> Output {
        var recording = recording
        var warning: [KeyCommand] = []
        if let at = input.keyTime, !recording.warned, at >= warnAt(recording) {
            // The warning's mark came first by this key's own time, though its timer has not been handled yet.
            recording.warned = true
            phase = .recording(recording)
            warning = [.oneMinuteLeft(recording.id)]
        }
        var output = keyWhileRecording(recording, input)
        output.commands = warning + output.commands
        return output
    }

    private mutating func keyWhileRecording(_ recording: Recording, _ input: KeyInput) -> Output {
        let id = recording.id
        if let at = input.keyTime, at >= capAt(recording) {
            // The cap came first, though its timer has not been handled yet.
            let capped = stopAtCap(recording)
            let after = idle(input)
            return Output(commands: capped.commands + after.commands, wakeAt: after.wakeAt)
        }
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
        case .ended(let ended):
            return forget(id, ifItIs: ended)
        case .escape(let at):
            guard at >= recording.began else { return Output() }  // the other report of an Esc that ended the last Dictation
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

    /// The Conductor ended `id` itself: forget it without a command. Any other id is stale.
    private mutating func forget(_ id: DictationID, ifItIs ended: DictationID) -> Output {
        if id == ended { phase = .idle }
        return Output()
    }

    private mutating func discard(_ id: DictationID) -> Output {
        phase = .idle
        return Output(commands: [.dictationDiscarded(id)])
    }

    /// Enters `.recording` and asks to wake at the warning.
    private mutating func confirm(_ id: DictationID, _ mode: DictationMode, began: HostTime) -> Output {
        let recording = Recording(id: id, mode: mode, began: began)
        phase = .recording(recording)
        return Output(commands: [.dictationConfirmed(id, mode)], wakeAt: warnAt(recording).advanced(by: Self.lateKeyGrace))
    }

    /// The cap clock: stop at `began + cap`, warn once before it, and always say
    /// when to wake next. An early or stale deadline just asks again.
    private mutating func capDeadline(_ recording: Recording, now: HostTime) -> Output {
        let acts = capAt(recording).advanced(by: Self.lateKeyGrace)
        if now >= acts { return stopAtCap(recording) }
        let warns = warnAt(recording).advanced(by: Self.lateKeyGrace)
        guard !recording.warned, now >= warns else {
            return Output(wakeAt: recording.warned ? acts : warns)
        }
        var warned = recording
        warned.warned = true
        phase = .recording(warned)
        return Output(commands: [.oneMinuteLeft(recording.id)], wakeAt: acts)
    }

    /// Stops at the cap's own time, with the warning first if its mark was never handled,
    /// so every capped Dictation is warned once and then stopped.
    private mutating func stopAtCap(_ recording: Recording) -> Output {
        let cap = capAt(recording)
        phase = .idle
        cappedAt = cap
        let warning: [KeyCommand] = recording.warned ? [] : [.oneMinuteLeft(recording.id)]
        return Output(commands: warning + [.dictationStopped(recording.id, at: cap)])
    }

    private func capAt(_ recording: Recording) -> HostTime { recording.began.advanced(by: config.cap) }

    private func warnAt(_ recording: Recording) -> HostTime {
        recording.began.advanced(by: config.cap - config.capWarning)
    }

    private func isHeld(_ since: HostTime, at time: HostTime) -> Bool {
        time >= since.advanced(by: config.holdThreshold)
    }
}

extension KeyInput {
    /// When a key or sleep happened; nil for the recognizer's own deadline and the Conductor's end.
    fileprivate var keyTime: HostTime? {
        switch self {
        case .fnDown(let at, _, _), .fnUp(let at), .otherKey(let at), .escape(let at), .sleep(let at): at
        case .deadline, .ended: nil
        }
    }
}

extension HostTime {
    func advanced(by duration: Duration) -> HostTime {
        let (seconds, attoseconds) = duration.components
        return HostTime(nanoseconds: UInt64(Int64(nanoseconds) + seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }
}
