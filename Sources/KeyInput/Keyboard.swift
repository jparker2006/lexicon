import CoreGraphics
import Foundation
public import LexiconDomain

/// What the keyboard asks Lexicon to do. The ONE list of key-driven actions:
/// `Conductor.handle` is an exhaustive switch over it.
///
/// Each fn press names its Dictation: the id minted at fn-down rides on every
/// command for that press, so a command can only ever act on its own Dictation.
public enum KeyCommand: Sendable, Hashable {
    /// fn went down (fn only in v0, no fallback hotkey, #18). Start capturing now, before we know
    /// whether this is a hold, the first half of a double tap, or a stray tap (#6).
    case dictationBegan(DictationID, at: HostTime)
    /// Held past the hold threshold, or second tap of a double tap.
    case dictationConfirmed(DictationID, DictationMode)
    /// Released after a hold, the next fn-down in hands-free, the Mac going to sleep, or the cap.
    case dictationStopped(DictationID, at: HostTime)
    /// Esc while recording (#18): nothing is typed, but the Dictation is still
    /// transcribed and saved to History, so paste-last gets it back.
    case dictationCancelled(DictationID)
    /// A stray tap that never became a Dictation. Its row and file are removed.
    case dictationDiscarded(DictationID)
    /// One minute until the cap stops this Dictation (the 19-minute mark).
    case oneMinuteLeft(DictationID)
    /// ⌃⌘V: paste the final text of the newest Dictation that has text.
    case pasteLast
    /// "I just fixed this" (#13 catch-all). Trigger key decided in #24.
    case justFixed
}

/// Key bindings and gesture timing, fixed in code (#18), re-checked in M0.
public struct KeyboardConfig: Sendable, Hashable {
    public var holdThreshold: Duration
    /// From the first fn-up to the second fn-down (#18; Jake's double-tap gap measured 31 to 93 ms).
    public var doubleTapWindow: Duration
    /// Every Dictation stops here, in either mode, as if fn were released (#18), counted
    /// from its first fn-down. A forgotten hands-free, or a lost fn-up, ends here.
    public var cap: Duration
    /// How long before the cap the warning sounds.
    public var capWarning: Duration
    /// None in v0 (#18): fn only. Kept as a seam for a non-Apple keyboard later.
    public var fallbackHotkey: Hotkey? = nil
    public var pasteLast: Hotkey = Hotkey(keyCode: 9, modifiers: [.control, .command])
    public var justFixed: Hotkey? = nil

    public init(holdThreshold: Duration = .milliseconds(300), doubleTapWindow: Duration = .milliseconds(250),
                cap: Duration = .seconds(20 * 60), capWarning: Duration = .seconds(60)) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.cap = cap
        self.capWarning = capWarning
    }
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
    /// macOS reports no access to listen to key events, which normally comes
    /// with Accessibility. The tap is not created, so no Input Monitoring prompt.
    case noListenAccess
}

/// The fn key and every other key Lexicon listens to.
///
/// Hides: the listen-only session-level CGEventTap on its own thread (#6), the
/// gesture state machine and its timer (the hold, the double tap and the cap),
/// passing every key on except Esc while recording (a registered hotkey takes
/// it), re-enabling the tap after the system disables it, ignoring events
/// Lexicon itself posted (its own Cmd-V), and stamping `InputClock`.
///
/// Gesture state has exactly one owner: the recognizer on the tap thread. Other
/// code asks it to change state (`systemWillSleep()`); nothing else writes it.
public final class Keyboard: Sendable {
    /// Ordered commands from the tap thread. Single consumer: `Conductor.follow`.
    public let commands: AsyncStream<KeyCommand>
    /// Hands an input to the recognizer on its own thread (the tap thread).
    let feed: @Sendable (KeyInput) -> Void
    /// The tap behind `feed`; nil for a test's scripted keyboard.
    let tap: EventTapThread?
    /// ⌃⌘V, registered for as long as the app runs (decision 59): taken from every
    /// app with no event tap, so no key waits on Lexicon. Held here only to keep it
    /// alive; nil for a test's keyboard, so a test run never takes ⌃⌘V from the Mac.
    let pasteLastKey: RegisteredHotkey?

    /// Creates the tap thread and starts listening. Throws if Accessibility is missing.
    public static func start(_ config: KeyboardConfig, input: InputClock) throws(KeyboardError) -> Keyboard {
        try start(config, input: input, listenAccess: CGPreflightListenEventAccess())
    }

    static func start(_ config: KeyboardConfig, input: InputClock, listenAccess: Bool) throws(KeyboardError) -> Keyboard {
        let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
        let tap = Self.tap(config, input: input, continuation: continuation)
        try tap.start(listenAccess: listenAccess)
        // The tap may see this key-down too; only the hotkey says paste, so one press pastes once.
        let pasteLast = RegisteredHotkey(config.pasteLast) { at in tap.send(.pasteLast, pressedAt: at) }
        pasteLast.setRegistered(true)
        return Keyboard(tap: tap, commands: commands, pasteLastKey: pasteLast)
    }

    /// The tap as `start` makes it, not yet started: tests drive it inline.
    static func tap(_ config: KeyboardConfig, input: InputClock,
                    continuation: AsyncStream<KeyCommand>.Continuation) -> EventTapThread {
        EventTapThread(gesture: FnGesture(config), input: input, continuation: continuation,
                       hotkeys: [config.pasteLast])
    }

    init(tap: EventTapThread, commands: AsyncStream<KeyCommand>, pasteLastKey: RegisteredHotkey? = nil) {
        self.commands = commands
        feed = { tap.perform($0) }
        self.tap = tap
        self.pasteLastKey = pasteLastKey
    }

    init(commands: AsyncStream<KeyCommand>, feed: @escaping @Sendable (KeyInput) -> Void) {
        self.commands = commands
        self.feed = feed
        tap = nil
        pasteLastKey = nil
    }

    /// Lid close or sleep is a normal stop (#4). It goes through the recognizer,
    /// so the stop joins `commands` behind every command already waiting there.
    public func systemWillSleep() { feed(.sleep(.now())) }

    /// The Conductor ended this Dictation itself (its mic never started). The
    /// recognizer forgets it, so Esc goes back to the apps and the next fn-down
    /// starts a new press instead of stopping one that is already over.
    public func dictationEnded(_ id: DictationID) { feed(.ended(id)) }
}
