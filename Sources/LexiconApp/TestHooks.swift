#if DEBUG
import AppKit
import os
import LexiconDomain
import AppText
import AudioCapture
import KeyInput
import LexiconUI
import TestHooks

/// The app's end of the test hooks: debug builds only, and on only for the dev
/// bundle id launched with `--test-hooks`. The daily app is a release build, so
/// none of this is in it (scripts/bundle.sh checks).
@MainActor
enum AppTestHooks {
    static func start(bundleID: String, paths: AppPaths, indicator: DictationIndicator) -> TestHookServer? {
        guard bundleID == AppPaths.devBundleID,
              CommandLine.arguments.contains(TestHookChannel.launchArgument) else { return nil }
        do {
            return try TestHookServer(channel: TestHookChannel(paths: paths)) { await handle($0, indicator: indicator) }
        } catch {
            Logger(subsystem: bundleID, category: "test-hooks")
                .error("test hooks did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func handle(_ command: TestHookCommand, indicator: DictationIndicator) async -> TestHookReply {
        switch command {
        case .status:
            .status(TestHookStatus(bundleID: Bundle.main.bundleIdentifier ?? "?",
                                   version: AppDelegate.version(of: .main), pid: getpid(),
                                   accessibility: Permissions.accessibility,
                                   microphone: Permissions.microphoneName))
        case .dictate:
            .failed("no live Dictation in the app yet: the Conductor is wired in by #56")
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
            await insert(text, after: delay)
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

    private static func showing(_ state: IndicatorState, on indicator: DictationIndicator) -> TestHookReply {
        // A steady level, so the recording states show their bars the way speech does.
        indicator.show(state, level: 0.6)
        return .done
    }

    /// The live paste path with no fn tap yet: one `TargetApp`, as `LexiconSystem`
    /// will own, and the same target-then-insert a Dictation makes.
    private static var text: TargetApp?

    private static func insert(_ text: String, after delay: Double) async -> TestHookReply {
        let app = self.text ?? TargetApp(input: InputClock())
        self.text = app
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
