import Foundation
import Synchronization

/// Keeps App Nap and timer coalescing from delaying a Dictation: a
/// `.userInitiated, .latencyCritical` activity from fn-down until the text
/// lands. Begins in `Conductor.handle(.dictationBegan)` (and `dictate(file:)`);
/// ends in `land` right after the insert, before a network wait, or when `run`
/// returns, whichever is first. `end` is idempotent.
final class LatencyHold: Sendable {
    private let token: Mutex<(any NSObjectProtocol)?>

    init(reason: String) {
        token = Mutex(ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: reason))
    }

    func end() {
        token.withLock { held in
            if let held { ProcessInfo.processInfo.endActivity(held) }
            held = nil
        }
    }
}
