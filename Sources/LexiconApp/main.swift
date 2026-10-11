import AppKit

// The app shell. scripts/bundle.sh assembles and signs Lexicon.app from the
// SwiftPM products (ADR 0003): it adds LSUIElement, NSMicrophoneUsageDescription,
// the audio-input entitlement, Hardened Runtime and signing (#14).
//
// `NSApplicationMain`, not a SwiftUI `App`: nothing here loads SwiftUI.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
