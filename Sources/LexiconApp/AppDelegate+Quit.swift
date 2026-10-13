import AppKit
import os
import AppText
import LexiconCore

// Quit, and the SIGTERM that install.sh and dev-run.sh send: a Dictation
// recording or finishing lands first, then Jake's clipboard comes back.

extension AppDelegate {
    /// `scripts/install.sh` and `scripts/dev-run.sh` quit the old copy with SIGTERM
    /// and wait for it to exit. A Dictation recording or finishing lands first
    /// (a recording one at its own fn-up), so an install never cuts a Dictation.
    /// The last paste's restore runs before the exit (at most 2 s more).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let system else { return .terminateNow }
        Task {
            await system.conductor.idle()
            await system.text.finishClipboard()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lexicon", category: "launch").notice("quitting")
    }

    /// SIGTERM ends the app through `terminate(_:)`, the same path as Quit, so
    /// `applicationShouldTerminate` gets its say. The default action would kill it outright.
    ///
    /// `terminate` runs as a run loop block, not inside this main-queue handler:
    /// with `.terminateLater` it spins the run loop until the reply, and the reply
    /// comes from a main-actor task, which can't run while the main queue is
    /// still inside this handler. Called from here, Quit would wait forever.
    static func terminateOnSIGTERM() -> any DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
            CFRunLoopWakeUp(main)
        }
        source.resume()
        return source
    }
}
