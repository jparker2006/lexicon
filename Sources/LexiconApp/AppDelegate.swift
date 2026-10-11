import AppKit
import os
import LexiconDomain
import LexiconCore
import LexiconUI
#if DEBUG
import TestHooks
#endif

/// Launch order (budget: fn works within 150 ms of process start):
/// 0. `LaunchGuard` (in main.swift): not launched by launchd -> message and exit, no event tap.
/// 1. `AppPaths.forBundle(id:)`; create the data folder.
/// 2. `LexiconSystem.live(...)`: opens SQLite, starts the event tap. If
///    Accessibility is missing, show onboarding instead (relaunch after grant). (#56, #57)
/// 3. Status item (now), then `AppUI.start()` with the indicator (#55).
/// 4. `Task { await system.run() }`: recovery, key loop, inbox loop, mic prepare. (#56)
/// 5. `SMAppService.mainApp.register()` when `startAtLogin` (no helper app). (#57)
/// 6. NSWorkspace will-sleep -> `conductor.systemWillSleep()`. (#56)
///
/// Test hooks (debug builds only) answer when the dev bundle id is launched with `--test-hooks`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var system: LexiconSystem?
    var statusItem: StatusItemController?
    var terminateOnSIGTERM: (any DispatchSourceSignal)?
    #if DEBUG
    var testHooks: TestHookServer?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        guard let bundleID = bundle.bundleIdentifier else { fatalError("Lexicon runs only as an app bundle") }
        let log = Logger(subsystem: bundleID, category: "launch")
        let paths = AppPaths.forBundle(id: bundleID)
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        } catch {
            log.error("cannot create the data folder: \(error.localizedDescription, privacy: .public)")
        }

        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lexicon"
        statusItem = StatusItemController(appName: appName, version: Self.version(of: bundle),
                                          extraItems: { Permissions.menuItems() })
        terminateOnSIGTERM = Self.terminateOnSIGTERM()
        #if DEBUG
        testHooks = AppTestHooks.start(bundleID: bundleID, paths: paths)
        #endif

        let permissions = Permissions.summary
        DispatchQueue.main.async {
            // One run loop turn after the status item exists: the closest in-process mark
            // for the icon being on screen (the window server composites it just after).
            let ms = { (seconds: Double?) in seconds.map { Int(($0 * 1000).rounded()) } ?? -1 }
            let icon = ms(LaunchClock.sinceProcessStart()), main = ms(LaunchClock.mainStarted)
            log.notice("""
                status item up \(icon, privacy: .public) ms after process start (main at \(main, privacy: .public) ms); \
                \(permissions, privacy: .public)
                """)
        }
    }

    /// Reopened from Spotlight or Finder: open History (#63). Nothing to show yet.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    /// `scripts/install.sh` and `scripts/dev-run.sh` quit the old copy with SIGTERM
    /// and wait for it to exit. There is no Dictation to wait for until the
    /// Conductor runs (#56); from then, this returns `.terminateLater` while a
    /// Dictation is recording or finishing and replies once it has landed, so an
    /// install never cuts a Dictation.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lexicon", category: "launch").notice("quitting")
        // TODO(#56): stop the recording Dictation as a normal stop; await history.flush() with a short cap.
    }

    /// SIGTERM ends the app through `terminate(_:)`, the same path as Quit, so
    /// `applicationShouldTerminate` gets its say. The default action would kill it outright.
    static func terminateOnSIGTERM() -> any DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
        source.resume()
        return source
    }

    /// "0.1 (412, 4dfdca8)": marketing version, build number, commit (set by scripts/bundle.sh).
    static func version(of bundle: Bundle) -> String {
        let info = { (key: String) in bundle.object(forInfoDictionaryKey: key) as? String ?? "?" }
        return "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")), \(info("LexiconCommit")))"
    }
}

/// Refuses to run the app when it was not launched by launchd (Finder, `open`,
/// login item: parent pid 1). Best effort: it stops the easy mistake, running
/// the binary from a shell, not a process that sets out to look launchd-started.
///
/// Why: a binary run straight from a shell inherits the shell host's
/// Accessibility trust (Terminal's, an agent's). Its event tap would then work
/// or fail for the wrong reason, and a grant made for it would land on the
/// wrong app. So a shell-launched Lexicon exits before AppKit starts, and never
/// installs the tap. It prints to stderr rather than showing an alert, so an
/// agent's shell gets the message instead of hanging on a modal.
enum LaunchGuard {
    static func refuseUnlessLaunchedByLaunchd() {
        guard getppid() != 1 else { return }
        let app = Bundle.main.bundlePath.hasSuffix(".app")
            ? Bundle.main.bundlePath : NSHomeDirectory() + "/Applications/Lexicon Dev.app"
        FileHandle.standardError.write(Data("""
            Lexicon must be launched by launchd, not from a shell: a shell-launched binary \
            inherits the shell's Accessibility trust. Run scripts/dev-run.sh, or: open "\(app)"

            """.utf8))
        exit(EX_USAGE)
    }
}

enum LaunchClock {
    /// When main.swift began, so the launch log can split dyld's share from ours.
    @MainActor static var mainStarted: Double?

    /// Seconds since this process was created, from the kernel's process start time.
    static func sinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1_000_000
    }
}
