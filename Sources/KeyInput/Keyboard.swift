import Foundation
public import LexiconDomain

/// What the keyboard asks Lexicon to do. The ONE list of key-driven actions:
/// `Conductor.handle` is an exhaustive switch over it.
public enum KeyCommand: Sendable, Hashable {
    /// fn went down (fn only in v0, no fallback hotkey, #18). Start capturing now, before we know
    /// whether this is a hold, the first half of a double tap, or a stray tap (#6).
    case dictationBegan(at: HostTime)
    /// Held past the hold threshold, or second tap of a double tap.
    case dictationConfirmed(DictationMode)
    /// Released after a hold, or the next fn-down in hands-free.
    case dictationStopped(at: HostTime)
    /// Esc while recording (#18): nothing is typed, but the Dictation is still
    /// transcribed and saved to History, so paste-last gets it back.
    case dictationCancelled
    /// A stray tap that never became a Dictation. Its row and file are removed.
    case dictationDiscarded
    /// ⌃⌘V: paste the final text of the newest Dictation that has text.
    case pasteLast
    /// "I just fixed this" (#13 catch-all). Trigger key decided in #24.
    case justFixed
}

/// Key bindings and gesture timing, fixed in code (#18), re-checked in M0.
public struct KeyboardConfig: Sendable, Hashable {
    public var holdThreshold: Duration = .milliseconds(300)
    /// From the first fn-up to the second fn-down (#18; Jake's double-tap gap measured 31 to 93 ms).
    public var doubleTapWindow: Duration = .milliseconds(250)
    /// None in v0 (#18): fn only. Kept as a seam for a non-Apple keyboard later.
    public var fallbackHotkey: Hotkey? = nil
    public var pasteLast: Hotkey = Hotkey(keyCode: 9, modifiers: [.control, .command])
    public var justFixed: Hotkey? = nil
    public init() {}
}

public struct Hotkey: Sendable, Hashable, Codable {
    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let command = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum KeyboardError: Error, Sendable {
    /// No Accessibility grant. Onboarding polls `AXIsProcessTrusted()` and offers a relaunch.
    case notTrusted
}

/// The fn key and every other key Lexicon listens to.
///
/// Hides: the active session-level CGEventTap on its own thread (#6), the
/// gesture state machine and its timer, passing every key on (Esc while
/// recording is swallowed from M1), re-enabling the tap after the system disables it, ignoring events
/// Lexicon itself posted (its own Cmd-V), and stamping `InputClock`.
///
/// Gesture state has exactly one owner: the recognizer on the tap thread. Other
/// code asks it to change state (`endDictation()`); nothing else writes it.
public final class Keyboard: Sendable {
    /// Ordered commands from the tap thread. Single consumer: `LexiconSystem`.
    public let commands: AsyncStream<KeyCommand>
    let tap: EventTapThread

    /// Creates the tap thread and starts listening. Throws if Accessibility is missing.
    public static func start(_ config: KeyboardConfig, input: InputClock) throws(KeyboardError) -> Keyboard {
        let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
        let tap = EventTapThread(gesture: FnGesture(holdThreshold: config.holdThreshold), input: input,
                                 continuation: continuation)
        try tap.start()
        return Keyboard(commands: commands, tap: tap)
    }

    init(commands: AsyncStream<KeyCommand>, tap: EventTapThread) {
        self.commands = commands
        self.tap = tap
    }

    /// The Dictation ended without a key (mic failure, sleep): leave the
    /// recording phase, so the release that follows does nothing.
    public func endDictation() { tap.perform(.externalEnd) }
}
