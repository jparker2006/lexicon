import AppKit

// The app shell. scripts/bundle.sh assembles and signs Lexicon.app from the
// SwiftPM products (ADR 0003): it adds LSUIElement, NSMicrophoneUsageDescription,
// the audio-input entitlement, Hardened Runtime and signing.
//
// `NSApplicationMain`, not a SwiftUI `App`: nothing here loads SwiftUI.
LaunchGuard.refuseUnlessLaunchedByLaunchd()
MainActor.assumeIsolated {
    LaunchClock.mainStarted = LaunchClock.sinceProcessStart()
    // NSApplication holds its delegate weakly: keep it alive for the whole run.
    let delegate = AppDelegate()
    // Before AppKit starts: the tap runs on its own thread, and the budget is fn
    // working within 150 ms of process start.
    // TODO(#56): delete `startKeyboard`, `keyboard` and the drain; `LexiconSystem.live` starts the tap
    // and `run()` hands its commands to `conductor.follow` (docs/architecture.md, Implementation reconciliation).
    delegate.startKeyboard()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
