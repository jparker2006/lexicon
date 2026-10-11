#if DEBUG
import AppKit
import os
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

    static func handle(_ command: TestHookCommand) -> TestHookReply {
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
        }
    }
}
#endif
