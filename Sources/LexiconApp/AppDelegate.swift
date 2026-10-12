import AppKit
import os
import LexiconDomain
import KeyInput
import LexiconCore
import LexiconUI
import LocalParakeet
#if DEBUG
import TestHooks
#endif

/// Launch order (budget: fn works within 150 ms of process start):
/// 0. `LaunchGuard` (in main.swift): not launched by launchd -> message and exit, no event tap.
/// 1. `startSystem()` (main.swift, before AppKit): the data folder, then
///    `LexiconSystem.live` (the fn tap first, then History, the Lexicon, AppText),
///    then `system.run()`: the key loop, crash recovery, mic prepare and the local model's load.
/// 2. `applicationDidFinishLaunching`: the status item and the indicator, which
///    follows the Conductor's events and the mic's levels; then `Setup`: start at
///    login, the warning dot, and the setup window on first run.
/// 3. NSWorkspace will-sleep -> `conductor.systemWillSleep()`; Quit waits for `conductor.idle()`.
///
/// Test hooks (debug builds only) answer when the dev bundle id is launched with `--test-hooks`;
/// such a run keeps its data in a scratch folder unless `--dev-data` is passed too.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var system: LexiconSystem?
    /// Why the system did not open (History's database), shown as a menu line.
    var systemError: String?
    var statusItem: StatusItemController?
    var indicator: DictationIndicator?
    var setup: Setup?
    var history: HistoryWindowPresenter?
    /// Nil until the Lexicon has opened, just after launch; its menu line appears then.
    var lexiconPage: LexiconWindowPresenter?
    var terminateOnSIGTERM: (any DispatchSourceSignal)?
    var sleepObserver: (any NSObjectProtocol)?
    /// The data root, chosen once in `startSystem`.
    var paths: AppPaths?
    #if DEBUG
    var testHooks: TestHookServer?
    /// The local model, slowed when a test hook asks.
    var slowModel: SlowedTranscriber?
    #endif

    /// Before AppKit starts: the tap runs on its own thread and the key loop off
    /// the main thread, so fn works while the app is still launching.
    func startSystem() {
        let bundle = Bundle.main
        guard let bundleID = bundle.bundleIdentifier else { fatalError("Lexicon runs only as an app bundle") }
        let log = Logger(subsystem: bundleID, category: "launch")
        #if DEBUG
        let paths = AppTestHooks.isOn(bundleID: bundleID)
            ? AppTestHooks.dataPaths(bundleID: bundleID) : AppPaths.forBundle(id: bundleID)
        // Inert until a test hook asks it to slow an answer.
        let local = SlowedTranscriber(ParakeetTranscriber(paths: paths))
        slowModel = local
        #else
        let paths = AppPaths.forBundle(id: bundleID)
        let local = ParakeetTranscriber(paths: paths)
        #endif
        self.paths = paths
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let system = try LexiconSystem.live(paths: paths, bundleID: bundleID, local: local)
            self.system = system
            Task.detached { await system.run() }
            let ms = LaunchClock.sinceProcessStart().map { Int(($0 * 1000).rounded()) } ?? -1
            if let fnOff = system.fnOff {
                log.error("""
                    fn is off: \(String(describing: fnOff), privacy: .public), \
                    accessibility=\(AXIsProcessTrusted(), privacy: .public)
                    """)
            } else {
                log.notice("fn working \(ms, privacy: .public) ms after process start")
            }
        } catch {
            systemError = "Lexicon can't open its History. Quit and reopen Lexicon."
            log.error("the system did not open: \(error.localizedDescription, privacy: .private)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier ?? "Lexicon"
        let log = Logger(subsystem: bundleID, category: "launch")
        let paths = paths ?? AppPaths.forBundle(id: bundleID)

        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lexicon"
        let history = HistoryWindowPresenter(paths: paths, system: system)
        self.history = history
        let statusItem = StatusItemController(appName: appName, version: Self.version(of: bundle)) { [weak self] in
            [history.menuItem()] + (self?.lexiconPage.map { [$0.menuItem()] } ?? [])
                + (self?.systemError.map { [Self.line($0)] } ?? [])
                + (self?.setup?.menuItems() ?? [])
                + (self?.indicator.map { [$0.privateModeMenuItem(), $0.soundsMenuItem()] } ?? [])
        }
        let preferences = system?.preferences ?? PreferencesStore()
        let indicator = DictationIndicator(statusItem: statusItem, preferences: preferences)
        // The system's Lexicon, the one every Dictation reads, so the page's edits reach the next fn-down.
        lexiconPage = system.map { LexiconWindowPresenter(lexicon: $0.lexicon) }
        self.statusItem = statusItem
        self.indicator = indicator
        if let system {
            Task {
                await indicator.follow(await system.conductor.events(), levels: system.recorder.levels)
            }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
            ) { _ in
                Task { await system.conductor.systemWillSleep() }
            }
        }
        terminateOnSIGTERM = Self.terminateOnSIGTERM()
        #if DEBUG
        testHooks = AppTestHooks.start(bundleID: bundleID, dataRoot: paths, indicator: indicator, system: system,
                                       preferences: preferences, slowModel: slowModel)
        #endif

        DispatchQueue.main.async { [weak self, system] in
            // One run loop turn after the status item exists: the closest in-process mark
            // for the icon being on screen (the window server composites it just after).
            let ms = { (seconds: Double?) in seconds.map { Int(($0 * 1000).rounded()) } ?? -1 }
            let icon = ms(LaunchClock.sinceProcessStart()), main = ms(LaunchClock.mainStarted)
            // After the mark: setup's first reads (Accessibility trust and the Microphone
            // answer, 20 to 50 ms cold, the login item, the model folder) need not hold the icon.
            let setup = Setup(statusItem: statusItem, preferences: preferences,
                              services: Self.setupServices(paths: paths, system: system),
                              relaunched: CommandLine.arguments.contains(Setup.relaunchArgument),
                              registersAtLogin: bundleID == AppPaths.dailyBundleID)
            self?.setup = setup
            setup.start()
            if let system { Task { await setup.follow(await system.conductor.events()) } }
            log.notice("""
                status item up \(icon, privacy: .public) ms after process start (main at \(main, privacy: .public) ms); \
                \(setup.permissionsSummary, privacy: .public)
                """)
            // After the mark, so the icon never waits for it; fn runs off the main thread.
            DispatchQueue.main.async { history.warmUp() }
        }
    }

    /// Reopened from Spotlight or Finder: open History.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        history?.show()
        return false
    }

    /// `scripts/install.sh` and `scripts/dev-run.sh` quit the old copy with SIGTERM
    /// and wait for it to exit. A Dictation recording or finishing lands first
    /// (a recording one at its own fn-up), so an install never cuts a Dictation.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let system else { return .terminateNow }
        Task {
            await system.conductor.idle()
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

    /// What setup needs from modules only the shell imports: the fn tap and the
    /// globe key (KeyInput), the model (LocalParakeet), the mic (the system's recorder).
    static func setupServices(paths: AppPaths, system: LexiconSystem?) -> Setup.Services {
        Setup.Services(
            fnOn: system != nil && system?.fnOff == nil,
            globeKeyOK: { !GlobeKey.hasSystemAction },
            modelInstalled: { ParakeetTranscriber.isInstalled(paths: paths) },
            installModel: { access, progress in
                try await ParakeetTranscriber.install(paths: paths, access: access, progress: progress)
            },
            modelInstalledNow: { await system?.loadModel() },
            microphoneGranted: {
                guard let system else { return }
                system.recorder.prepare(.microphone(deviceUID: system.preferences.snapshot().microphoneUID))
            })
    }

    /// A menu line that only informs.
    static func line(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
