#if DEBUG
import AppKit
import os
import LexiconCore
import LexiconDomain
import AppText
import AudioCapture
import KeyInput
import LexiconCore
import LexiconUI
import TestHooks

/// The app's end of the test hooks: debug builds only, and on only for the dev
/// bundle id launched with `--test-hooks`. The daily app is a release build, so
/// none of this is in it (scripts/bundle.sh checks).
@MainActor
enum AppTestHooks {
    static func start(bundleID: String, paths: AppPaths, indicator: DictationIndicator,
                      system: LexiconSystem?, preferences: PreferencesStore) -> TestHookServer? {
        guard bundleID == AppPaths.devBundleID,
              CommandLine.arguments.contains(TestHookChannel.launchArgument) else { return nil }
        do {
            return try TestHookServer(channel: TestHookChannel(paths: paths)) {
                await handle($0, indicator: indicator, system: system, preferences: preferences)
            }
        } catch {
            Logger(subsystem: bundleID, category: "test-hooks")
                .error("test hooks did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func handle(_ command: TestHookCommand, indicator: DictationIndicator,
                       system: LexiconSystem?, preferences: PreferencesStore) async -> TestHookReply {
        return switch command {
        case .status:
            .status(currentStatus(preferences))
        case .privacy(let mode, let alwaysPrivateApps):
            privacy(mode, alwaysPrivateApps: alwaysPrivateApps, preferences: preferences)
        case .dictate(let wav):
            if let system { await dictate(URL(filePath: wav), on: system) } else { closed }
        case .indicator(let state):
            showing(state, on: indicator)
        case .sound(let cue):
            if let latency = await indicator.playAndMeasure(cue) {
                .soundPlayed(latency: latency)
            } else {
                .failed("the \(cue.rawValue) sound did not play: Sounds is off, or no output device")
            }
        case .capture(let seconds, let preparedIdle, let deviceChange, let deviceUID):
            await capture(seconds: seconds, preparedIdle: preparedIdle, deviceChange: deviceChange, deviceUID: deviceUID)
        case .insert(let text, let delay):
            if let system { await insert(text, after: delay, into: system.text) } else { closed }
        }
    }

    /// Off the main actor: the probe sleeps while the mic records.
    nonisolated static func capture(seconds: Double, preparedIdle: Double?, deviceChange: Bool,
                                    deviceUID: String?) async -> TestHookReply {
        do {
            return .capture(try await MicProbe.measure(seconds: seconds, preparedIdle: preparedIdle, deviceChange: deviceChange,
                                                       deviceUID: deviceUID, folder: FileManager.default.temporaryDirectory))
        } catch {
            return .failed("the mic did not start: \(error)")
        }
    }

    private static func currentStatus(_ preferences: PreferencesStore) -> TestHookStatus {
        let settings = preferences.snapshot()
        return TestHookStatus(bundleID: Bundle.main.bundleIdentifier ?? "?",
                              version: AppDelegate.version(of: .main), pid: getpid(),
                              accessibility: AXIsProcessTrusted(),
                              microphone: Setup.microphoneName,
                              privacy: settings.privacy, alwaysPrivateApps: settings.alwaysPrivateApps.sorted())
    }

    /// The store the menu and the Conductor read, so a change is saved and a relaunch keeps it.
    private static func privacy(_ mode: PrivacyMode, alwaysPrivateApps: [String]?,
                                preferences: PreferencesStore) -> TestHookReply {
        preferences.update { settings in
            settings.privacy = mode
            if let alwaysPrivateApps { settings.alwaysPrivateApps = Set(alwaysPrivateApps) }
        }
        return .status(currentStatus(preferences))
    }

    private static func showing(_ state: IndicatorState, on indicator: DictationIndicator) -> TestHookReply {
        // A steady level, so the recording states show their bars the way speech does.
        indicator.show(state, level: 0.6)
        return .done
    }

    private static let closed = TestHookReply.failed("the app did not open its History, so nothing runs")

    /// The live path on a WAV: the same run as fn, typed into the focused field at
    /// the end of the file, at the speed of speech. Test fixtures only: a file in a
    /// `fixtures` folder or the temporary folder, so a hook can never feed the Test
    /// set's audio (or anything else of Jake's) into a field.
    private static func dictate(_ wav: URL, on system: LexiconSystem) async -> TestHookReply {
        guard isFixture(wav) else {
            return .failed("dictate takes a test fixture: a WAV in a fixtures folder or the temporary folder")
        }
        let result = await system.conductor.dictate(file: wav, pace: .realtime)
        return .dictated(TestHookDictation(status: result.status?.rawValue, lagMillis: result.lag.map { micros($0) / 1_000 },
                                           model: result.model?.id, characters: result.versions?.cleaned.count))
    }

    /// The live paste path alone: the system's `TargetApp`, and the same
    /// target-then-insert a Dictation makes.
    private static func insert(_ text: String, after delay: Double, into app: TargetApp) async -> TestHookReply {
        try? await Task.sleep(for: .seconds(max(0, min(delay, 20))))
        let before = access()
        let bundleID = await app.context().bundleID
        let clock = ContinuousClock()
        let start = clock.now
        guard let target = await app.target() else { return .failed("nothing has keyboard focus") }
        let targetTime = clock.now - start
        let delivery = await app.insert(text, for: DictationID(), at: target)
        let receipt: InsertionReceipt? = if case .inserted(let receipt) = delivery { receipt } else { nil }
        let outcome = switch delivery {
        case .inserted: "inserted"
        case .notInserted(let reason): reason.rawValue
        case .historyOnly: "historyOnly"
        }
        return .inserted(TestHookInsertion(
            bundleID: bundleID, outcome: outcome, targetMicros: micros(targetTime),
            pasteWorkMicros: await app.lastPasteWork.map(micros), hasFingerprint: receipt?.fieldFingerprint != nil,
            caretAfter: receipt?.caretAfter, contextBeforeCount: receipt?.contextBefore.count ?? 0,
            contextAfterCount: receipt?.contextAfter.count ?? 0, clipboardAccessBefore: before,
            clipboardAccessAfter: access()))
    }

    static func isFixture(_ url: URL) -> Bool {
        let components = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.pathComponents }
        let path = components(url)
        let inside = { (folder: [String]) in Array(path.prefix(folder.count)) == folder }
        // Never a data folder, whatever it is called: that is where the Test set lives.
        let data = [AppPaths.dailyBundleID, AppPaths.devBundleID].map { components(AppPaths.forBundle(id: $0).root) }
        guard !data.contains(where: inside) else { return false }
        return path.dropLast().contains("fixtures") || inside(components(FileManager.default.temporaryDirectory))
            || inside(["/", "private", "tmp"])
    }

    private static func access() -> String {
        switch NSPasteboard.general.accessBehavior {
        case .default: "default"
        case .ask: "ask"
        case .alwaysAllow: "alwaysAllow"
        case .alwaysDeny: "alwaysDeny"
        @unknown default: "unknown"
        }
    }

    private static func micros(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000_000 + Int(duration.components.attoseconds / 1_000_000_000_000)
    }
}
#endif
