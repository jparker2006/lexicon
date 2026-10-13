#if DEBUG
import AppKit
import os
import LexiconDomain
import AppText
import AudioCapture
import KeyInput
import LexiconCore
import LexiconUI
import LocalParakeet
import TestHooks

/// The app's end of the test hooks: debug builds only, and on only for the dev
/// bundle id launched with `--test-hooks`. The daily app is a release build, so
/// none of this is in it (scripts/bundle.sh checks).
@MainActor
enum AppTestHooks {
    static func isOn(bundleID: String) -> Bool {
        bundleID == AppPaths.devBundleID && CommandLine.arguments.contains(TestHookChannel.launchArgument)
    }

    /// The fn timing for this launch: with `--test-hooks --short-cap`, a 20 s cap
    /// whose warning sounds 5 s before it, so Live checks hears both in one sitting.
    static func keyboardConfig(bundleID: String) -> KeyboardConfig {
        guard isOn(bundleID: bundleID), CommandLine.arguments.contains(TestHookChannel.shortCapArgument) else {
            return KeyboardConfig()
        }
        return KeyboardConfig(cap: .seconds(20), capWarning: .seconds(5))
    }

    /// A test-hooks run's data root: a scratch folder whose models link to the
    /// dev app's, so synthetic Dictations never land in its History. The dev
    /// app's own folder with `--dev-data`.
    static func dataPaths(bundleID: String) -> AppPaths {
        let own = AppPaths.forBundle(id: bundleID)
        let paths = TestHookChannel.dataRoot(forBundle: bundleID, arguments: CommandLine.arguments)
        guard paths != own else { return own }
        do {
            try ParakeetTranscriber.shareModels(of: own, with: paths)
        } catch {
            // Dictations wait for a model rather than the run touching the dev app's data.
            Logger(subsystem: bundleID, category: "test-hooks")
                .error("the scratch data root has no model: \(error.localizedDescription, privacy: .public)")
        }
        return paths
    }

    /// The wire is always under the dev app's own root, wherever its data
    /// goes, so the harness finds it without knowing the run's flags.
    static func start(bundleID: String, dataRoot: AppPaths, indicator: DictationIndicator,
                      system: LexiconSystem?, preferences: PreferencesStore,
                      slowModel: SlowedTranscriber?) -> TestHookServer? {
        guard isOn(bundleID: bundleID) else { return nil }
        let context = Context(dataRoot: dataRoot, indicator: indicator, system: system, preferences: preferences,
                              slowModel: slowModel)
        do {
            return try TestHookServer(channel: TestHookChannel(paths: AppPaths.forBundle(id: bundleID))) {
                await handle($0, in: context)
            }
        } catch {
            Logger(subsystem: bundleID, category: "test-hooks")
                .error("test hooks did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    struct Context {
        let dataRoot: AppPaths
        let indicator: DictationIndicator
        let system: LexiconSystem?
        let preferences: PreferencesStore
        let slowModel: SlowedTranscriber?
    }

    static func handle(_ command: TestHookCommand, in context: Context) async -> TestHookReply {
        let (indicator, system, preferences) = (context.indicator, context.system, context.preferences)
        return switch command {
        case .status:
            .status(currentStatus(preferences, dataRoot: context.dataRoot))
        case .privacy(let mode, let alwaysPrivateApps):
            privacy(mode, alwaysPrivateApps: alwaysPrivateApps, preferences: preferences, dataRoot: context.dataRoot)
        case .dictate(let wav, let resultDelay):
            if let system {
                await dictate(URL(filePath: wav), on: system, slowing: context.slowModel, by: resultDelay)
            } else {
                closed
            }
        case .keys(let keys):
            if let keyboard = system?.keyboard {
                press(keys, on: keyboard)
            } else {
                .failed("fn is off (no Accessibility or no listen access), so no key reaches the tap")
            }
        case .sleep:
            // What the app's NSWorkspace will-sleep observer calls.
            if let system { await sleep(system) } else { closed }
        case .silenceMic:
            if let system { silenceMic(system) } else { closed }
        case .dropAudio:
            if let system { dropAudio(system) } else { closed }
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

    private static func currentStatus(_ preferences: PreferencesStore, dataRoot: AppPaths) -> TestHookStatus {
        let settings = preferences.snapshot()
        return TestHookStatus(bundleID: Bundle.main.bundleIdentifier ?? "?",
                              version: AppDelegate.version(of: .main), pid: getpid(),
                              accessibility: AXIsProcessTrusted(),
                              microphone: Setup.microphoneName,
                              privacy: settings.privacy, alwaysPrivateApps: settings.alwaysPrivateApps.sorted(),
                              dataRoot: dataRoot.root.path(percentEncoded: false))
    }

    /// The store the menu and the Conductor read, so a change is saved and a relaunch keeps it.
    private static func privacy(_ mode: PrivacyMode, alwaysPrivateApps: [String]?,
                                preferences: PreferencesStore, dataRoot: AppPaths) -> TestHookReply {
        preferences.update { settings in
            settings.privacy = mode
            if let alwaysPrivateApps { settings.alwaysPrivateApps = Set(alwaysPrivateApps) }
        }
        return .status(currentStatus(preferences, dataRoot: dataRoot))
    }

    /// Into the fn tap's own handler, back to back on its thread, so `fn down
    /// up down` is a double tap however slowly the harness runs. The reply
    /// comes once they are queued; the log shows what the recognizer did.
    private static func press(_ keys: [TestHookKey], on keyboard: Keyboard) -> TestHookReply {
        for key in keys {
            let synthetic: SyntheticKey = switch key {
            case .fnDown(let shift): .fnDown(shift: shift)
            case .fnUp(let shift): .fnUp(shift: shift)
            case .escape: .escape
            }
            keyboard.press(synthetic)
        }
        return .done
    }

    private static func sleep(_ system: LexiconSystem) async -> TestHookReply {
        await system.conductor.systemWillSleep()
        return .done
    }

    private static func silenceMic(_ system: LexiconSystem) -> TestHookReply {
        system.recorder.silenceNextMicrophoneCapture()
        return .done
    }

    private static func dropAudio(_ system: LexiconSystem) -> TestHookReply {
        system.recorder.dropNextCaptureBlock()
        return .done
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
    private static func dictate(_ wav: URL, on system: LexiconSystem, slowing model: SlowedTranscriber?,
                                by resultDelay: Double?) async -> TestHookReply {
        guard isFixture(wav) else {
            return .failed("dictate takes a test fixture: a WAV in a fixtures folder or the temporary folder")
        }
        let dictate = { @Sendable in await system.conductor.dictate(file: wav, pace: .realtime) }
        let result = if let model, let resultDelay {
            await model.slowing(by: .seconds(max(0, min(resultDelay, 120))), dictate)
        } else {
            await dictate()
        }
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
