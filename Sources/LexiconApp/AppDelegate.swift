import AppKit
import LexiconDomain
import LexiconCore
import LexiconUI
import LocalParakeet

/// Launch order (budget: fn works within 150 ms of process start):
/// 0. `LaunchGuard`: not launched by launchd -> alert and quit, no event tap (#14).
/// 1. `AppPaths.forBundle(id:)`; create directories.
/// 2. `LexiconSystem.live(...)`: opens SQLite, starts the event tap. If
///    Accessibility is missing, show onboarding instead (relaunch after grant).
/// 3. `AppUI.start()`: status item.
/// 4. `Task { await system.run() }`: recovery, key loop, inbox loop, mic prepare.
/// 5. `SMAppService.mainApp.register()` when `startAtLogin` (no helper app).
/// 6. NSWorkspace will-sleep -> `conductor.systemWillSleep()`.
///
/// Test hooks are on only for the dev bundle id AND `--test-hooks` (#14).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var system: LexiconSystem?
    var ui: AppUI?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard LaunchGuard.launchedByLaunchd else {
            LaunchGuard.refuse()  // no event tap, no system: just the alert, then quit
            return
        }
        // TODO: steps 1-6 above.
        fatalError("not implemented")
    }

    /// Reopened from Spotlight or Finder: open History (#4).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        fatalError("not implemented")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO: stop the recording Dictation as a normal stop; await history.flush() with a short cap.
        fatalError("not implemented")
    }
}

/// Refuses to run the app when it was not launched by launchd (Finder, `open`,
/// login item: parent pid 1).
///
/// Why (#14): a binary run straight from a shell inherits the shell host's
/// Accessibility trust (Terminal's, an agent's). Its event tap would then work
/// or fail for the wrong reason, and a grant made for it would land on the
/// wrong app. So a shell-launched Lexicon never installs the tap; it shows an
/// alert telling the builder to launch with `open "~/Applications/Lexicon Dev.app"`.
@MainActor
enum LaunchGuard {
    static var launchedByLaunchd: Bool { getppid() == 1 }

    /// NSAlert: "Launch Lexicon with `open`, not from a shell (#14)", then terminate.
    static func refuse() {
        // TODO: let alert = NSAlert(); messageText/informativeText as above; alert.runModal();
        // NSApplication.shared.terminate(nil)
        fatalError("not implemented")
    }
}
