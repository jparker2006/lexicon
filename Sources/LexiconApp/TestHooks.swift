#if DEBUG
import AppKit
import os
import LexiconDomain
import AudioCapture
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
}
#endif
