import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os
import LexiconDomain

/// The tap thread. Owns the CGEventTap, its run loop, the gesture recognizer and
/// its deadline timer. Internal: nothing outside KeyInput can reach a CGEvent.
///
/// Callback budget: a few microseconds. It (1) re-enables the tap if the system
/// disabled it, (2) drops events Lexicon itself posted (its own Cmd-V), (3) ticks
/// the InputClock on key-down / mouse-down, (4) feeds fn and every other key-down
/// to `FnGesture` and yields its commands, (5) passes every event on: nothing is
/// swallowed in M0.
///
/// `@unchecked Sendable` is safe because `gesture` and `deadline` are touched
/// only on the tap thread (the callback, the timer and `perform`'s blocks all
/// run on its run loop), and `tap` and `runLoop` are written once in `start()`
/// before it returns, ordered by the semaphore.
final class EventTapThread: @unchecked Sendable {
    private var gesture: FnGesture
    private var deadline: CFRunLoopTimer?
    private let input: InputClock
    private let continuation: AsyncStream<KeyCommand>.Continuation
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ownPID = Int64(getpid())
    private let log = Logger(subsystem: "Lexicon", category: "fn")

    init(gesture: FnGesture, input: InputClock, continuation: AsyncStream<KeyCommand>.Continuation) {
        self.gesture = gesture
        self.input = input
        self.continuation = continuation
    }

    /// Creates the tap (session level, active, mask: flagsChanged, keyDown,
    /// leftMouseDown, rightMouseDown), then spawns the thread that runs it.
    /// Throws `.notTrusted` without Accessibility: the tap is the permission check.
    func start() throws(KeyboardError) {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw .notTrusted }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, self.tap, 0), .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Lexicon fn tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Posted onto the tap thread's run loop, never run inline.
    func perform(_ input: KeyInput) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { self.feed(input) }
        CFRunLoopWakeUp(runLoop)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.error("fn tap was disabled (\(type.rawValue, privacy: .public)); re-enabled")
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != ownPID else { return pass }
        if type != .flagsChanged { input.tick() }
        guard let key = KeyInput(event, secureInput: { IsSecureEventInputEnabled() }, now: .now()) else { return pass }
        feed(key)
        switch key {
        case .fnDown(let at, _): logDelivery("down", at: at, stamp: event.timestamp)
        case .fnUp(let at): logDelivery("up", at: at, stamp: event.timestamp)
        default: break
        }
        return pass
    }

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
    private func logDelivery(_ edge: StaticString, at: HostTime, stamp: CGEventTimestamp) {
        let now = HostTime.now()
        let micros = Int(now.duration(since: at) / .microseconds(1))
        // TODO(#53 live check): the raw stamp and now settle which timestamp reading is right; then drop them.
        log.notice("""
            fn \(String(describing: edge), privacy: .public) delivered \(micros, privacy: .public) µs after the key \
            (stamp \(stamp, privacy: .public), now \(now.nanoseconds, privacy: .public) ns)
            """)
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
        let at = HostTime(eventTimestamp: event.timestamp, now: now)
        switch event.type {
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else { return nil }
            self = event.flags.contains(.maskSecondaryFn) ? .fnDown(at, secureInput: secureInput()) : .fnUp(at)
        case .keyDown:
            self = .otherKey(at)
        default:
            return nil
        }
    }
}

extension HostTime {
    /// A CGEvent's timestamp on the HostTime clock. An event posted without a
    /// time (stamp 0), or one that reads as not yet happened or over a second
    /// old, is taken as `now`.
    init(eventTimestamp stamp: CGEventTimestamp, now: HostTime) {
        // TODO(#53 live check): the header says "roughly nanoseconds"; keep whichever reading the live log proves.
        let readings = [HostTime(nanoseconds: stamp),
                        HostTime(nanoseconds: stamp * machTimebase.numer / machTimebase.denom)]
        self = readings.first { $0 <= now && now.duration(since: $0) < .seconds(1) } ?? now
    }
}

private let machTimebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
}()
