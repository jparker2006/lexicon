import AppKit
import AVFAudio
import KeyInput

/// The two grants Lexicon needs, as menu lines: "Microphone: allowed", or an
/// "Allow Microphone…" item that asks. Plus one line while the globe key has a
/// system action, read each time the menu opens (#53). A stopgap so a build can be granted and
/// its grants checked across rebuilds; first-run setup and the warning dot
/// replace it (#57).
@MainActor
enum Permissions {
    static var microphone: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// "granted", "denied" or "undetermined".
    static var microphoneName: String {
        switch microphone {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        @unknown default: "unknown"
        }
    }

    /// For the launch log line, read by the grant check in the PR evidence.
    /// Input Monitoring is never requested: the active fn tap needs Accessibility only.
    /// Logged so a working tap with `inputMonitoring=false` proves it (#53).
    static var summary: String {
        "accessibility=\(accessibility) microphone=\(microphoneName) inputMonitoring=\(CGPreflightListenEventAccess())"
    }

    static func menuItems() -> [NSMenuItem] {
        [
            microphone == .granted
                ? status("Microphone: allowed")
                : action("Allow Microphone…", Handler.shared, #selector(Handler.requestMicrophone)),
            accessibility
                ? status("Accessibility: allowed")
                : action("Allow Accessibility…", Handler.shared, #selector(Handler.requestAccessibility)),
        ] + (GlobeKey.hasSystemAction
            ? [action("Set “Press globe key to” to Do Nothing…", Handler.shared, #selector(Handler.openKeyboardSettings))]
            : [])
    }

    private static func status(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func action(_ title: String, _ target: AnyObject, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        return item
    }

    @MainActor
    final class Handler: NSObject {
        static let shared = Handler()

        /// The macOS prompt the first time; after a denial only System Settings can change it.
        @objc func requestMicrophone() {
            if Permissions.microphone == .undetermined {
                AVAudioApplication.requestRecordPermission { _ in }
            } else {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
        }

        /// The system prompt adds Lexicon to the Accessibility list and offers to open System Settings.
        @objc func requestAccessibility() {
            let prompt = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }

        /// Jake changes it there; Lexicon never writes the setting.
        @objc func openKeyboardSettings() {
            open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        }

        private func open(_ url: String) {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
    }
}
