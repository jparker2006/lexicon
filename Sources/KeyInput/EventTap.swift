import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os
import LexiconDomain

/// The tap thread. Owns the CGEventTap, its run loop, the gesture recognizer and
/// its deadline timer. Internal: nothing outside KeyInput can reach a CGEvent.
///
/// Listen-only: macOS hands the tap a copy and delivers every key at once. An
/// active tap holds each key until Lexicon's thread answers: keys reached apps
/// 26 to 74 ms after they were pressed with it, 2 to 12 ms with listen-only.
/// M0 swallows nothing (Esc while recording comes in M1).
///
/// The callback (1) re-enables the tap if the system disabled it, (2) drops
/// events Lexicon itself posted (its own Cmd-V), (3) ticks the InputClock on
/// key-down / mouse-down, (4) feeds fn and every other key-down to `FnGesture`
/// and yields its commands.
///
/// `@unchecked Sendable` is safe because `gesture`, `deadline` and the hotkey counts are touched
/// by one thread only: the tap thread (the callback, the timer and `perform`'s
/// blocks all run on its run loop), or a test's thread for a tap never started.
/// `tap` and `runLoop` are written once in `start()` before it returns, ordered
/// by the semaphore.
final class EventTapThread: @unchecked Sendable {
    private var gesture: FnGesture
    private var deadline: CFRunLoopTimer?
    private let input: InputClock
    private let continuation: AsyncStream<KeyCommand>.Continuation
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ownPID = Int64(getpid())
    /// Asked on fn-down. Tests pass their own: the real one is system-wide state.
    private let secureInput: @Sendable () -> Bool
    /// Lexicon's own hotkeys (⌃⌘V). One press can reach this thread twice, as the
    /// tap's copy of its key-down and as the hotkey's `send`, in either order (or
    /// only once, if the hotkey never registered or the tap never saw the key). It is
    /// one keystroke: the first report ticks, and the other report of it does not.
    private let hotkeys: [Hotkey]
    /// Presses one report counted and the other has not come in yet. Tap thread only.
    private var tapCopiesAhead = 0, hotkeyPressesAhead = 0
    private let log = Logger(subsystem: "Lexicon", category: "fn")

    init(gesture: FnGesture, input: InputClock, continuation: AsyncStream<KeyCommand>.Continuation,
         secureInput: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }, hotkeys: [Hotkey] = []) {
        self.gesture = gesture
        self.input = input
        self.continuation = continuation
        self.secureInput = secureInput
        self.hotkeys = hotkeys
    }

    /// Creates the tap (session level, listen-only, mask: flagsChanged, keyDown
    /// and the three mouse-downs), then spawns the thread that runs it.
    /// Throws `.notTrusted` without Accessibility: the tap is the permission check.
    /// Listen access is checked first, so creating the tap can never raise an
    /// Input Monitoring prompt.
    func start(listenAccess: Bool) throws(KeyboardError) {
        guard listenAccess else { throw .noListenAccess }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // Unretained is safe: the thread below captures self and its run loop never exits.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw .notTrusted }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, self.tap, 0), .commonModes)
            CFRunLoopAddTimer(runLoop, self.watchdog(), .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Lexicon fn tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Every 2 s: turns the tap back on if macOS turned it off without the
    /// disabled event the callback handles, which leaves fn dead with nothing in
    /// the log. Seen live once, right after a fresh install's first paste.
    private func watchdog() -> CFRunLoopTimer {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0) { [self] _ in
            guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            reenable(because: "no notice")
        }!
        CFRunLoopTimerSetTolerance(timer, 0.5)
        return timer
    }

    private func reenable(because reason: StaticString) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log.error("fn tap was disabled (\(String(describing: reason), privacy: .public)); re-enabled")
        input.tick()  // Jake may have typed while it was off: late text must not assume he didn't
        // An fn-up lost while the tap was off would leave the mic recording until the next press.
        if gesture.isRecording, !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
            feed(.fnUp(.now()))
        }
    }

    /// Posted onto the tap thread's run loop, never run inline. A tap never
    /// started (tests) runs it at once, on the caller's thread.
    func perform(_ input: KeyInput) {
        onTapThread { self.feed(input) }
    }

    /// A Lexicon hotkey's press (⌃⌘V), yielded on the tap thread so it queues behind
    /// every fn command already sent: `commands` keeps one producer. The press is Jake
    /// typing, counted before its command unless the tap's copy already counted it
    /// (`hotkeys`): a Dictation still on its way is held, and the paste this press
    /// asks for marks after the press, so its own key-down never holds it.
    /// A tap never started (tests) runs it at once, on the caller's thread.
    func send(_ command: KeyCommand) {
        onTapThread { [self] in
            if tapCopiesAhead > 0 {
                tapCopiesAhead -= 1
            } else {
                input.tick()
                hotkeyPressesAhead += 1
            }
            continuation.yield(command)
            log.notice("key command: \(String(describing: command), privacy: .public)")
        }
    }

    func onTapThread(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop else { return work() }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Tap thread only (the callback); tests call it on a tap never started.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(because: type == .tapDisabledByTimeout ? "timeout" : "user input")
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != ownPID else { return pass }
        if Self.isTypingOrClicking(type) { countTyping(event) }
        guard let key = KeyInput(event, secureInput: secureInput, now: .now()) else { return pass }
        feed(key)
        switch key {
        case .fnDown(let at, _, _): logDelivery("down", at: at)
        case .fnUp(let at): logDelivery("up", at: at)
        default: break
        }
        return pass
    }

    /// One tick per keystroke; a hotkey press the hotkey's `send` already counted is not another.
    private func countTyping(_ event: CGEvent) {
        guard hotkeys.contains(where: { $0.matches(event) }) else { return input.tick() }
        if hotkeyPressesAhead > 0 {
            hotkeyPressesAhead -= 1
        } else {
            input.tick()
            tapCopiesAhead += 1
        }
    }

    /// What counts as Jake typing or clicking for `InputClock`: key-downs and
    /// mouse-downs. Modifier changes never count, so fn-up is not "typed since".
    static func isTypingOrClicking(_ type: CGEventType) -> Bool { type != .flagsChanged }

    private func feed(_ key: KeyInput) {
        let output = gesture.handle(key)
        for command in output.commands {
            continuation.yield(command)
            log.notice("fn gesture: \(String(describing: command), privacy: .public)")
        }
        if let wakeAt = output.wakeAt { schedule(wakeAt) }
    }

    /// One timer slot: a new deadline replaces the old one, and a stale one that
    /// still fires is ignored by the recognizer (it judges by time).
    private func schedule(_ wakeAt: HostTime) {
        guard let runLoop else { return }  // a tap never started (tests): fn-up still judges the hold
        if let deadline { CFRunLoopTimerInvalidate(deadline) }
        let (whole, atto) = wakeAt.duration(since: .now()).components
        let seconds = Double(whole) + Double(atto) / 1e18
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + max(seconds, 0), 0, 0, 0) {
            [self] _ in feed(.deadline(.now()))
        }
        deadline = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    /// fn delivery latency through the tap: the key event's own time to now.
    private func logDelivery(_ edge: StaticString, at: HostTime) {
        let micros = Int(HostTime.now().duration(since: at) / .microseconds(1))
        log.notice("fn \(String(describing: edge), privacy: .public) delivered \(micros, privacy: .public) µs after the key")
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTapThread>.fromOpaque(info).takeUnretainedValue().handle(type, event)
}

extension KeyInput {
    /// The fn key's virtual keycode (kVK_Function).
    static let fnKeyCode: Int64 = 63

    /// What the recognizer sees of one event, or nil for an event it ignores.
    /// fn is a flag change on keycode 63; every other flag change (Shift, Cmd,
    /// Option, Control, Caps Lock) is ignored, so a modifier never cancels.
    /// `secureInput` is asked only on fn-down.
    init?(_ event: CGEvent, secureInput: () -> Bool, now: HostTime) {
        switch event.type {
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else { return nil }
            let at = HostTime(eventTimestamp: event.timestamp, now: now)
            self = event.flags.contains(.maskSecondaryFn)
                ? .fnDown(at, secureInput: secureInput(), id: DictationID()) : .fnUp(at)
        case .keyDown:
            self = .otherKey(HostTime(eventTimestamp: event.timestamp, now: now))
        default:
            return nil
        }
    }
}

extension Hotkey {
    /// This key-down, with exactly these modifiers among Command, Option, Control and Shift.
    func matches(_ event: CGEvent) -> Bool {
        guard event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) else {
            return false
        }
        let flags: [(Modifiers, CGEventFlags)] = [(.command, .maskCommand), (.option, .maskAlternate),
                                                  (.control, .maskControl), (.shift, .maskShift)]
        return flags.allSatisfy { modifiers.contains($0.0) == event.flags.contains($0.1) }
    }
}

extension HostTime {
    /// A CGEvent's timestamp is nanoseconds on the HostTime clock. An event posted
    /// without a time (stamp 0), or one that reads as not yet happened or over a
    /// second old, is taken as `now`, so a bad stamp can't turn a tap into a hold.
    init(eventTimestamp stamp: CGEventTimestamp, now: HostTime) {
        let at = HostTime(nanoseconds: stamp)
        self = at <= now && now.duration(since: at) < .seconds(1) ? at : now
    }
}
