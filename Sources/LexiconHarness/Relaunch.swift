#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

/// `lexicon-harness relaunch [--release] [--test-hooks [--dev-data]]`: quits the
/// running Lexicon Dev the way Quit does (a Dictation recording or finishing
/// lands first), opens the installed copy again, and prints the launch timings
/// it logs. A warm relaunch: the reading the launch budget uses.
@MainActor
func relaunch(_ arguments: [String]) async throws {
    let flags = Set(arguments)
    guard flags.isSubset(of: ["--release", "--test-hooks", "--dev-data"]), flags.count == arguments.count,
          !flags.contains("--dev-data") || flags.contains("--test-hooks") else { fail(usage, code: 64) }
    let release = flags.contains("--release"), hooks = flags.contains("--test-hooks")
    guard !(release && hooks) else { throw HarnessError("a release build has no test hooks: drop --release or --test-hooks") }

    // scripts/bundle.sh fails a release bundle holding this name, so its presence says debug.
    let binary = DevApp.installed.appending(path: "Contents/MacOS/Lexicon")
    let isDebug = try Data(contentsOf: binary).range(of: Data("TestHook".utf8)) != nil
    if release, isDebug { throw HarnessError("the installed Lexicon Dev is a debug build. Install a release one: scripts/dev-run.sh --release") }
    if hooks, !isDebug { throw HarnessError("the installed Lexicon Dev is a release build, which has no test hooks. Install a debug one: scripts/dev-run.sh") }

    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.devBundleID).first {
        let pid = running.processIdentifier
        running.terminate()
        // Quit waits for a Dictation to land, and for one stuck in the model up to 30 s.
        _ = try await HistoryCheck.poll("Lexicon Dev (pid \(pid)) to quit", every: .milliseconds(50), within: .seconds(60)) {
            running.isTerminated ? true : nil
        }
        ok("quit Lexicon Dev (pid \(pid))")
    }

    let since = Date()
    let appArguments = (hooks ? [TestHookChannel.launchArgument] : []) + (flags.contains("--dev-data") ? [TestHookChannel.devDataArgument] : [])
    try await run("/usr/bin/open", ["-g", DevApp.installed.path] + (appArguments.isEmpty ? [] : ["--args"] + appArguments))
    if hooks {
        let app = try await DevApp.launch()
        ok("Lexicon Dev \(app.status.version) answers test hooks (pid \(app.status.pid)), data in \(app.status.dataRoot)")
    }
    // The launch lines land a moment after the status item is up.
    let lines = try await HistoryCheck.poll("Lexicon Dev's launch lines in the log", every: .milliseconds(250), within: .seconds(15)) {
        let found = try await launchLines(since: since)
        return found.contains { $0.contains("status item up") } ? found : nil
    }
    for line in lines { ok(line) }
}

/// The dev app's own launch log lines since `since`: fn working, the status item.
func launchLines(since: Date) async throws -> [String] {
    let seconds = Int(-since.timeIntervalSinceNow.rounded(.up)) + 2
    let (_, output) = try await runChild("/usr/bin/log", [
        "show", "--style", "compact", "--last", "\(seconds)s", "--predicate",
        "subsystem == \"\(AppPaths.devBundleID)\" && category == \"launch\" && processImagePath CONTAINS \"/Lexicon Dev.app/\"",
    ])
    return output.split(separator: "\n").compactMap { line in
        guard let match = line.firstMatch(of: /(fn working .*|fn is off.*|status item up \d+ ms after process start[^;]*)/) else { return nil }
        return String(match.1)
    }
}
#endif
