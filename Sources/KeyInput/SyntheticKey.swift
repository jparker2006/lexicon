#if DEBUG
import Carbon.HIToolbox
import CoreGraphics

/// A key the test hooks press in Lexicon Dev (`hook fn`, `hook key esc`).
/// Debug builds only. Built as the CGEvent a keyboard sends and handed to the
/// tap's own handler on the tap thread, so it takes every step a real key takes
/// after macOS delivers it: the own-paste filter, the InputClock, the
/// translation into `KeyInput` and the recognizer. What it skips is macOS
/// itself: key timing, a tap the system disabled, and anything that acts on
/// the event in flight.
public enum SyntheticKey: Sendable, Hashable {
    /// fn goes down or up; `shift`: Shift is held at the time.
    case fnDown(shift: Bool)
    case fnUp(shift: Bool)
    case escape

    /// The event a keyboard sends: fn is a flag change on keycode 63, Esc a
    /// key-down. Stamped as coming from the hardware (pid 0), so the tap never
    /// takes it for Lexicon's own Cmd-V, and unstamped in time, so it reads as now.
    var event: CGEvent? {
        let (keyCode, flags): (Int, CGEventFlags) = switch self {
        case .fnDown(let shift): (kVK_Function, shift ? [.maskSecondaryFn, .maskShift] : .maskSecondaryFn)
        case .fnUp(let shift): (kVK_Function, shift ? .maskShift : [])
        case .escape: (kVK_Escape, [])
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
            return nil
        }
        if keyCode == kVK_Function { event.type = .flagsChanged }
        event.flags = flags
        event.timestamp = 0
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }
}

extension EventTapThread {
    /// The tap thread's handler, as if the tap had seen `key`. A tap never
    /// started (tests) handles it on the caller's thread.
    func press(_ key: SyntheticKey) {
        onTapThread { [self] in
            guard let event = key.event else { return }
            _ = handle(event.type, event)
        }
    }
}

extension Keyboard {
    /// Test hooks: `key` through the fn tap's own handler, behind whatever it
    /// is handling now. Does nothing when fn is off (no tap).
    public func press(_ key: SyntheticKey) { tap?.press(key) }
}
#endif
