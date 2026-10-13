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
/// The tap swallows nothing. Esc while recording is taken by a registered
/// hotkey that follows the recognizer's `takesEscape` (ADR 0004).
///
/// The callback (1) re-enables the tap if the system disabled it, (2) drops
/// events Lexicon itself posted (its own Cmd-V), (3) ticks the InputClock on
/// key-down / mouse-down, (4) feeds fn and every other key-down to `FnGesture`
/// and yields its commands, (5) takes or gives back Esc when that changed.
///
/// `@unchecked Sendable` is safe because `gesture`, `deadline` and `tookEscape`
/// are touched by one thread only: the tap thread (the callback, the timer and
/// `perform`'s blocks all run on its run loop), or a test's thread for a tap
/// never started. `tap` and `takeEscape` are set in `init` or in `start()`
/// before the thread starts; `runLoop` is set on the new thread before it
/// signals the semaphore that `start()` waits on, so it is set before
/// `start()` returns.
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
    /// Whether fn is down right now, asked after the tap was off with a press in
    /// progress. System-wide state; tests pass their own. Reading it needs listen
    /// access, which the tap is created only with.
    private let fnHeld: @Sendable () -> Bool
    private let log = Logger(subsystem: "Lexicon", category: "fn")
    /// Takes Esc from the app in front (true) or gives it back (false): the
    /// Esc hotkey once started, a test's recorder otherwise.
    private var takeEscape: @Sendable (Bool) -> Void
    /// What `takeEscape` was last told, so it hears only changes.
    private var tookEscape = false

    init(gesture: FnGesture, input: InputClock, continuation: AsyncStream<KeyCommand>.Continuation,
         secureInput: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
         fnHeld: @escaping @Sendable () -> Bool = {
             CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
         },
         takeEscape: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.gesture = gesture
        self.input = input
        self.continuation = continuation
        self.secureInput = secureInput
        self.fnHeld = fnHeld
        self.takeEscape = takeEscape
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
        // The hotkey's press is the same Esc the tap may also see: the recognizer acts on the first.
        let escape = RegisteredHotkey(.escape) { [self] at in perform(.escape(at)) }
        takeEscape = { escape.setRegistered($0) }
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
            // The cause is unknown; the grants name a lost permission if it happens again.
            reenable(because: "no notice", grants: "; accessibility \(AXIsProcessTrusted()), listen \(CGPreflightListenEventAccess())")
        }!
        CFRunLoopTimerSetTolerance(timer, 0.5)
        return timer
    }

    private func reenable(because reason: StaticString, grants: String = "") {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log.error("fn tap was disabled (\(String(describing: reason), privacy: .public)\(grants, privacy: .public)); re-enabled")
        input.tick()  // Jake may have typed while it was off: late text must not assume he didn't
        // An fn-up lost while the tap was off would leave the mic recording until the next press.
        if gesture.isRecording, !fnHeld() {
            feed(.fnUp(.now()))
        }
    }

    /// Posted onto the tap thread's run loop, never run inline. A tap never
    /// started (tests) runs it at once, on the caller's thread.
    func perform(_ input: KeyInput) {
        onTapThread { self.feed(input) }
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
        if Self.isTypingOrClicking(type), !KeyInput.isFnItself(event) { input.tick() }
        guard let key = KeyInput(event, secureInput: secureInput, now: .now()) else { return pass }
        #if DEBUG
        let pressing = gesture.isRecording && !gesture.takesEscape  // a press or a tap not yet confirmed
        #endif
        feed(key)
        #if DEBUG
        // Dev builds only: which key ended an unconfirmed press, so a live check can tell a
        // real chord from a key macOS sends for fn itself. Never in the daily app.
        if case .otherKey = key, pressing, !gesture.isRecording {
            log.notice("fn press ended by key \(event.getIntegerValueField(.keyboardEventKeycode), privacy: .public)")
        }
        #endif
        switch key {
        case .fnDown(let at, _, _): logDelivery("down", at: at)
        case .fnUp(let at): logDelivery("up", at: at)
        default: break
        }
        return pass
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
        if let wakeAt = output.wakeAt { schedule(Deadline(due: wakeAt, rearmed: false)) }
        if gesture.takesEscape != tookEscape {
            tookEscape = gesture.takesEscape
            takeEscape(tookEscape)
        }
    }

    /// One timer slot: a new deadline replaces the old one, and a stale one that
    /// still fires is ignored by the recognizer (it judges by time).
    private func schedule(_ next: Deadline) {
        guard let runLoop else { return }  // a tap never started (tests): fn-up still judges the hold
        if let deadline { CFRunLoopTimerInvalidate(deadline) }
        let (whole, atto) = next.due.duration(since: .now()).components
        let seconds = Double(whole) + Double(atto) / 1e18
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + max(seconds, 0), 0, 0, 0) {
            [self] _ in deadlineFired(next, now: .now())
        }
        deadline = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    /// A pending deadline: when it is due, and whether it is already the one
    /// re-arm a late timer gets.
    struct Deadline: Equatable {
        let due: HostTime
        let rearmed: Bool
    }

    /// A timer later than this may have been held up by a stall, with keys queued behind it.
    static let lateTimer: Duration = .milliseconds(1)
    /// How long a late timer waits for those keys (Jake, DECISIONS.md item 93).
    static let queuedKeysWait: Duration = .milliseconds(5)

    /// A deadline timer fired at `now`. Tap thread only; tests call it on a tap
    /// never started, where a re-arm does nothing.
    func deadlineFired(_ pending: Deadline, now: HostTime) {
        if let next = Self.fired(pending, now: now) { schedule(next) } else { feed(.deadline(now)) }
    }

    /// nil means feed `.deadline(now)`; otherwise schedule the returned re-arm.
    /// Fn edges keep their own stamps, so after a stall the run loop may run a
    /// timer before the keys queued during it, and judge a hold or a window on a
    /// late `now` before seeing a short tap's fn-up, a chord's key or a double tap's
    /// second press. A timer over `lateTimer` late waits `queuedKeysWait` so those
    /// go first. Only once: the re-arm always feeds, so a handler that keeps
    /// freezing can't hold off the cap.
    static func fired(_ pending: Deadline, now: HostTime) -> Deadline? {
        guard !pending.rearmed, now.duration(since: pending.due) > lateTimer else { return nil }
        return Deadline(due: now.advanced(by: queuedKeysWait), rearmed: true)
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
    /// The Globe key's keycode in a key-down. With the Globe key, macOS can send a
    /// key-down for fn itself when a short tap is released (its own Globe action);
    /// that is fn, not another key, so it must not end the tap as a chord would.
    static let globeKeyCode: Int64 = 179

    /// A key-down for fn itself: not another key and not typing.
    static func isFnItself(_ event: CGEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        return keyCode == fnKeyCode || keyCode == globeKeyCode
    }

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
            guard !Self.isFnItself(event) else { return nil }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let at = HostTime(eventTimestamp: event.timestamp, now: now)
            // Plain Esc, fn or not (a hold keeps fn down); with Cmd, Option, Control or Shift it is a shortcut.
            let plain = event.flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl, .maskShift])
            self = keyCode == Int64(kVK_Escape) && plain
                ? .escape(at) : .otherKey(at)
        default:
            return nil
        }
    }
}

extension HostTime {
    /// A CGEvent's timestamp is nanoseconds on the HostTime clock. An event posted
    /// without a time (stamp 0), or one that reads as not yet happened, is taken as
    /// `now`. An old stamp is kept: when the tap thread stalls, both edges of a long
    /// hold arrive late, and only their own times still read as a hold.
    init(eventTimestamp stamp: CGEventTimestamp, now: HostTime) {
        let at = HostTime(nanoseconds: stamp)
        self = stamp != 0 && at <= now ? at : now
    }
}
