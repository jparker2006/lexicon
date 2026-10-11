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
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
