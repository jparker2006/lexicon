import CoreGraphics
import Foundation
import LexiconDomain

/// The tap thread. Owns the CGEventTap, its run loop, the gesture recognizer and
/// its timers. Internal: nothing outside KeyInput can reach a CGEvent.
///
/// Callback budget: a few microseconds. It (1) drops events whose
/// `kCGEventSourceUnixProcessID` is our own pid (our Cmd-V), (2) ticks the
/// InputClock on key-down / mouse-down, (3) feeds fn and every other key-down to
/// `FnGesture`, (4) yields commands to the AsyncStream continuation, (5) returns
/// nil to swallow only what the recognizer said to swallow. Synthetic fn from
/// other processes is accepted on purpose: the head-to-head harness posts it (#15).
/// fn-down while secure event input is on (a password field has focus,
/// `IsSecureEventInputEnabled()`) starts nothing: password fields are never
/// dictated into, in any mode (#5).
final class EventTapThread: @unchecked Sendable {
    // Confined to the tap thread after start().
    var gesture: FnGesture
    let input: InputClock
    let continuation: AsyncStream<KeyCommand>.Continuation

    init(gesture: FnGesture, input: InputClock, continuation: AsyncStream<KeyCommand>.Continuation) {
        self.gesture = gesture
        self.input = input
        self.continuation = continuation
    }

    /// Spawns the thread, creates the tap (session level, active, mask:
    /// flagsChanged, keyDown, leftMouseDown, rightMouseDown), adds it to the
    /// thread's run loop. Throws `.notTrusted` without Accessibility.
    func start() throws(KeyboardError) {
        fatalError("not implemented")
    }

    /// Posted onto the tap thread's run loop (CFRunLoopPerformBlock), never run inline.
    func perform(_ input: KeyInput) {
        fatalError("not implemented")
    }
}
