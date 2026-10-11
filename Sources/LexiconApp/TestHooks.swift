#if DEBUG
import AppKit
import os
import AppText
import KeyInput
import LexiconDomain
import TestHooks

/// The app's end of the test hooks: debug builds only, and on only for the dev
/// bundle id launched with `--test-hooks`. The daily app is a release build, so
/// none of this is in it (scripts/bundle.sh checks).
@MainActor
enum AppTestHooks {
    static func start(bundleID: String, paths: AppPaths) -> TestHookServer? {
        guard bundleID == AppPaths.devBundleID,
              CommandLine.arguments.contains(TestHookChannel.launchArgument) else { return nil }
        do {
            return try TestHookServer(channel: TestHookChannel(paths: paths)) { await handle($0) }
        } catch {
            Logger(subsystem: bundleID, category: "test-hooks")
                .error("test hooks did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func handle(_ command: TestHookCommand) async -> TestHookReply {
        switch command {
        case .status:
            .status(TestHookStatus(bundleID: Bundle.main.bundleIdentifier ?? "?",
                                   version: AppDelegate.version(of: .main), pid: getpid(),
                                   accessibility: Permissions.accessibility,
                                   microphone: Permissions.microphoneName))
        case .dictate:
            .failed("no live Dictation in the app yet: the Conductor is wired in by #56")
        case .indicator:
            .failed("no indicator yet: the pill and menu bar states come with #55")
        case .insert(let text, let delay):
            await insert(text, after: delay)
        }
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
