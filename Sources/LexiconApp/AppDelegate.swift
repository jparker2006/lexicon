import AppKit
import os
import LexiconDomain
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
///
/// Each feature it wires is one `AppDelegate+` file; this one holds launch.
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
        let bundleID = Bundle.main.bundleIdentifier ?? "Lexicon"
        let paths = paths ?? AppPaths.forBundle(id: bundleID)
        let preferences = system?.preferences ?? PreferencesStore()
        let history = makeWindows(paths: paths)
        let (statusItem, indicator) = showStatusItem(history: history, preferences: preferences)
        followSleep()
        terminateOnSIGTERM = Self.terminateOnSIGTERM()
        #if DEBUG
        testHooks = AppTestHooks.start(bundleID: bundleID, dataRoot: paths, indicator: indicator, system: system,
                                       preferences: preferences, slowModel: slowModel)
        #endif

        DispatchQueue.main.async { [weak self] in
            self?.startSetup(statusItem: statusItem, preferences: preferences, paths: paths, bundleID: bundleID)
        }
    }
}
