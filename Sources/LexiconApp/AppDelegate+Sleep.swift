import AppKit
import LexiconCore

// Lid close or sleep: a normal stop for a recording Dictation (#4).

extension AppDelegate {
    func followSleep() {
        guard let system else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in
            Task { await system.conductor.systemWillSleep() }
        }
    }
}
