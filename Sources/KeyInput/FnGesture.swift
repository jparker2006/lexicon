import LexiconDomain

/// What the tap thread feeds the recognizer. Built from CGEvents in EventTap.swift.
enum KeyInput: Sendable, Hashable {
    /// `secureInput`: macOS secure event input was on (a password field has focus).
    case fnDown(HostTime, secureInput: Bool)
    case fnUp(HostTime)
    /// Any other key-down. Modifiers (Shift included) are flag changes, never key-downs,
    /// so they never get here: Shift with fn never cancels (it is the Re-speak trigger in M4).
    case otherKey(HostTime)
    /// A timer the recognizer asked for has fired.
    case deadline(HostTime)
    /// The core ended the Dictation (see `Keyboard.endDictation`).
    case externalEnd
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
        case pressed(since: HostTime)
        case holding
    }

    struct Output: Sendable, Hashable {
        var commands: [KeyCommand] = []
        /// Ask the driver to deliver `.deadline` at this time.
        var wakeAt: HostTime?
    }

    private(set) var phase: Phase = .idle
    let holdThreshold: Duration

    init(holdThreshold: Duration) {
        self.holdThreshold = holdThreshold
    }

    var isRecording: Bool { phase != .idle }

    mutating func handle(_ input: KeyInput) -> Output {
        switch (phase, input) {
        case (.idle, .fnDown(let at, secureInput: false)):
            phase = .pressed(since: at)
            return Output(commands: [.dictationBegan(at: at)], wakeAt: at.advanced(by: holdThreshold))

        case (.pressed(let since), .deadline(let now)) where isHeld(since, at: now):
            phase = .holding
            return Output(commands: [.dictationConfirmed(.hold)])

        case (.pressed(let since), .fnUp(let at)):
            phase = .idle
            return isHeld(since, at: at)
                ? Output(commands: [.dictationConfirmed(.hold), .dictationStopped(at: at)])
                : Output(commands: [.dictationDiscarded])

        case (.pressed(let since), .otherKey(let at)):
            if isHeld(since, at: at) {
                phase = .holding
                return Output(commands: [.dictationConfirmed(.hold)])
            }
            phase = .idle
            return Output(commands: [.dictationDiscarded])

        case (.holding, .fnUp(let at)):
            phase = .idle
            return Output(commands: [.dictationStopped(at: at)])

        case (_, .externalEnd):
            phase = .idle
            return Output()

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
