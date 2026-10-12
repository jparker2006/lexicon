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

/// The fn gesture state machine (#53, M0: hold only). Pure: no clocks, no
/// threads, no CGEvent. Unit-tested with scripted inputs. Internal to KeyInput.
///
///     idle --fnDown--> pressed                  emits .dictationBegan (recording starts now)
///     idle --fnDown, secure input on--> idle    nothing: a password field is never dictated into
///     pressed --held >= threshold--> holding    emits .dictationConfirmed(.hold)
///     pressed --fnUp before threshold--> idle   emits .dictationDiscarded (lone tap: nothing in History)
///     pressed --otherKey before threshold--> idle  emits .dictationDiscarded (a shortcut like fn+arrow)
///     holding --otherKey--> holding             passed through; recording continues
///     holding --fnUp--> idle                    emits .dictationStopped
///     pressed or holding --sleep--> idle        as fnUp at that time
///
/// The id on fn-down names the Dictation; every command for that press carries it.
///
/// Every input carries the event's own time, and the threshold is judged on it,
/// not on when a timer happened to fire: fn-up or a key at 0.31 s still counts
/// as a hold even if the 0.30 s deadline has not been delivered yet.
///
/// Every event passes through: fn, and any key, whether or not it cancels.
/// Hands-free (double tap), Esc and the 20-minute cap come in M1.
struct FnGesture: Sendable {
    enum Phase: Sendable, Hashable {
        case idle
        case pressed(DictationID, since: HostTime)
        case holding(DictationID)
    }

    struct Output: Sendable, Hashable {
        var commands: [KeyCommand] = []
        /// Ask the driver to deliver `.deadline` at this time.
        var wakeAt: HostTime?
    }

    private(set) var phase: Phase = .idle
    let holdThreshold: Duration

    init(_ config: KeyboardConfig) {
        holdThreshold = config.holdThreshold
    }

    var isRecording: Bool { phase != .idle }

    /// Esc is taken from the app in front exactly while this is true.
    var takesEscape: Bool { false }

    mutating func handle(_ input: KeyInput) -> Output {
        switch (phase, input) {
        case (.idle, .fnDown(let at, secureInput: false, let id)):
            phase = .pressed(id, since: at)
            return Output(commands: [.dictationBegan(id, at: at)], wakeAt: at.advanced(by: holdThreshold))

        case (.pressed(let id, let since), .deadline(let now)):
            // A timer that fires a hair early asks again rather than leaving the hold unconfirmed.
            guard isHeld(since, at: now) else { return Output(wakeAt: since.advanced(by: holdThreshold)) }
            phase = .holding(id)
            return Output(commands: [.dictationConfirmed(id, .hold)])

        case (.pressed(let id, let since), .fnUp(let at)):
            phase = .idle
            return isHeld(since, at: at)
                ? Output(commands: [.dictationConfirmed(id, .hold), .dictationStopped(id, at: at)])
                : Output(commands: [.dictationDiscarded(id)])

        case (.pressed(let id, let since), .otherKey(let at)):
            if isHeld(since, at: at) {
                phase = .holding(id)
                return Output(commands: [.dictationConfirmed(id, .hold)])
            }
            phase = .idle
            return Output(commands: [.dictationDiscarded(id)])

        case (.holding(let id), .fnUp(let at)):
            phase = .idle
            return Output(commands: [.dictationStopped(id, at: at)])

        case (.idle, .sleep):
            return Output()

        case (_, .sleep(let at)):
            // Lid close or sleep ends a press the way letting go of fn would. The stop
            // goes out on the same stream as the press's other commands, so it can
            // never land on a Dictation that started after it.
            return handle(.fnUp(at))

        default:
            // fn-down while already recording (its fn-up was lost), a stale
            // deadline, a key while holding or idle: nothing to do.
            return Output()
        }
    }

    private func isHeld(_ since: HostTime, at time: HostTime) -> Bool {
        time >= since.advanced(by: holdThreshold)
    }
}

extension HostTime {
    func advanced(by duration: Duration) -> HostTime {
        let (seconds, attoseconds) = duration.components
        return HostTime(nanoseconds: UInt64(Int64(nanoseconds) + seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }
}
