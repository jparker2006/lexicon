#if DEBUG
import Foundation
public import LexiconDomain

// Test hooks: how a harness asks the running Lexicon Dev to do something and
// hears back. Debug builds only. Every file in this module is `#if DEBUG`, so a
// release build (the daily app) holds none of it, and scripts/bundle.sh fails a
// release bundle that does.
//
// The wire is a pair of folders under the app's data root, like the inbox:
// the harness writes `test-hooks/requests/<id>.json` (atomically), the app
// handles it, deletes it and writes `test-hooks/replies/<id>.json`. Not the
// inbox itself: the inbox is one-way and at most once, and a harness needs an
// answer. Files rather than a socket: no listener thread, and the boundary is
// the user's own data folder: any process running as Jake can drive the dev
// app while it runs with `--test-hooks`, which is why hooks never ship.

/// Everything a harness can ask. The app's handler is an exhaustive switch over it.
public enum TestHookCommand: Codable, Sendable, Equatable {
    /// Who is running, and its grants.
    case status
    /// Dictate this WAV through the live path, typing into the focused field.
    /// `resultDelay`: the local model answers this many seconds late.
    case dictate(wav: String, resultDelay: Double?)
    /// Press keys through the fn tap's own handler, in order, back to back.
    case keys([TestHookKey])
    /// The Mac is going to sleep, as NSWorkspace says it.
    case sleep
    /// The next Dictation's mic delivers only zeros.
    case silenceMic
    /// The next Dictation, from the mic or a file, loses its first block, counted as lost audio.
    case dropAudio
    /// Show one indicator state on the pill and the menu bar icon.
    case indicator(IndicatorState)
    /// Play one sound and report how long it took to reach the speaker.
    case sound(SoundCue)
    /// Record from the mic for `seconds` and measure it (#52). `preparedIdle`:
    /// prepare the engine as at launch and wait this long before fn-down; nil
    /// builds it on fn-down (cold). `deviceChange`: rebuild the engine halfway,
    /// as when hardware changes. `deviceUID` nil: built-in mic.
    case capture(seconds: Double, preparedIdle: Double?, deviceChange: Bool, deviceUID: String?)
    /// Paste `text` at the cursor through the real AppText path, as a Dictation
    /// would at fn-up: capture the focused field after `delay` seconds (time to
    /// click into the field), then insert.
    case insert(text: String, delay: Double)
    /// Turn Private mode on or off. A non-nil `alwaysPrivateApps` replaces the
    /// always-private list: nil leaves it as it is, [] clears it. Replies with the status.
    case privacy(PrivacyMode, alwaysPrivateApps: [String]?)
}

/// A key `keys` presses, as the keyboard would send it.
public enum TestHookKey: Codable, Sendable, Equatable {
    case fnDown(shift: Bool)
    case fnUp(shift: Bool)
    case escape
}

public enum TestHookReply: Codable, Sendable, Equatable {
    case status(TestHookStatus)
    case done
    /// From the call to play until its first sample reaches the output device.
    case soundPlayed(latency: Duration)
    case capture(MicMeasurement)
    case inserted(TestHookInsertion)
    case dictated(TestHookDictation)
    /// The app understood the command but could not do it; the text says why.
    case failed(String)
}

public struct TestHookStatus: Codable, Sendable, Equatable {
    public let bundleID: String
    /// "0.1 (412, 4dfdca8)": marketing version, build number, commit.
    public let version: String
    public let pid: Int32
    public let accessibility: Bool
    /// "granted", "denied" or "undetermined".
    public let microphone: String
    public let privacy: PrivacyMode
    /// Sorted, so two replies for the same settings are equal.
    public let alwaysPrivateApps: [String]
    /// Where History, audio and the Lexicon go: a scratch folder unless the app
    /// was launched with `--dev-data`.
    public let dataRoot: String

    /// The commit the app was built from: "4dfdca8" in "0.1 (412, 4dfdca8)".
    public var commit: String? {
        version.firstMatch(of: /, ([0-9a-f]{7,40})\)$/).map { String($0.1) }
    }

    public init(bundleID: String, version: String, pid: Int32, accessibility: Bool, microphone: String,
                privacy: PrivacyMode, alwaysPrivateApps: [String], dataRoot: String) {
        self.bundleID = bundleID
        self.version = version
        self.pid = pid
        self.accessibility = accessibility
        self.microphone = microphone
        self.privacy = privacy
        self.alwaysPrivateApps = alwaysPrivateApps
        self.dataRoot = dataRoot
    }
}

/// What one `insert` did. Counts and timings only: the field's text never
/// leaves the app through a hook, since the field can be one of Jake's.
public struct TestHookInsertion: Codable, Sendable, Equatable {
    /// The focused app at capture.
    public let bundleID: String?
    /// "inserted", or the `NotInsertedReason`.
    public let outcome: String
    /// Capturing the field at "fn-up", and the insert's own work up to Cmd-V, in microseconds.
    public let targetMicros: Int
    public let pasteWorkMicros: Int?
    public let hasFingerprint: Bool
    public let caretAfter: Int?
    public let contextBeforeCount: Int
    public let contextAfterCount: Int
    /// `NSPasteboard.general.accessBehavior` before and after: how macOS treats
    /// Lexicon reading the clipboard ("default", "ask", "alwaysAllow", "alwaysDeny").
    public let clipboardAccessBefore: String
    public let clipboardAccessAfter: String

    public init(bundleID: String?, outcome: String, targetMicros: Int, pasteWorkMicros: Int?, hasFingerprint: Bool,
                caretAfter: Int?, contextBeforeCount: Int, contextAfterCount: Int,
                clipboardAccessBefore: String, clipboardAccessAfter: String) {
        self.bundleID = bundleID
        self.outcome = outcome
        self.targetMicros = targetMicros
        self.pasteWorkMicros = pasteWorkMicros
        self.hasFingerprint = hasFingerprint
        self.caretAfter = caretAfter
        self.contextBeforeCount = contextBeforeCount
        self.contextAfterCount = contextAfterCount
        self.clipboardAccessBefore = clipboardAccessBefore
        self.clipboardAccessAfter = clipboardAccessAfter
    }
}

/// What one `dictate` did. No text: it can land in one of Jake's fields.
public struct TestHookDictation: Codable, Sendable, Equatable {
    /// The Dictation's status ("inserted", "notInserted", "waiting", ...), nil if nothing was recorded.
    public let status: String?
    /// End of file (its "fn-up") to the target app reading the paste.
    public let lagMillis: Int?
    /// The engine that won, as History names it ("local:parakeetUnified").
    public let model: String?
    public let characters: Int?

    public init(status: String?, lagMillis: Int?, model: String?, characters: Int?) {
        self.status = status
        self.lagMillis = lagMillis
        self.model = model
        self.characters = characters
    }
}

public enum TestHookError: Error, Equatable {
    /// Nothing answered in time: the app is not running, or runs without `--test-hooks`.
    case noReply
}

public struct TestHookChannel: Sendable {
    /// The launch argument that turns hooks on, for the dev bundle id only:
    /// `open "Lexicon Dev.app" --args --test-hooks`.
    public static let launchArgument = "--test-hooks"
    /// With `launchArgument`: keep the dev app's own data folder instead of a
    /// scratch one, for checks that need its real History or Lexicon.
    public static let devDataArgument = "--dev-data"

    /// A test-hooks run's data root: the scratch one, so synthetic Dictations
    /// never land in the dev app's History, or its own with `devDataArgument`.
    public static func dataRoot(forBundle bundleID: String, arguments: [String]) -> AppPaths {
        arguments.contains(devDataArgument) ? AppPaths.forBundle(id: bundleID) : AppPaths.scratch(forBundle: bundleID)
    }

    /// A request older than this is dropped unanswered. Its sender gave up long
    /// ago, and a stale "dictate" must never type into whatever has focus at the
    /// next launch.
    static let staleAfter: TimeInterval = 30

    let requests: URL
    let replies: URL

    public init(paths: AppPaths) {
        let root = paths.root.appending(path: "test-hooks", directoryHint: .isDirectory)
        requests = root.appending(path: "requests", directoryHint: .isDirectory)
        replies = root.appending(path: "replies", directoryHint: .isDirectory)
    }

    /// Harness side: post one command and wait for its reply.
    public func send(_ command: TestHookCommand, timeout: Duration) async throws -> TestHookReply {
        try await reply(to: post(command), timeout: timeout)
    }

    /// Writes one request. Its file name names its reply too.
    func post(_ command: TestHookCommand) throws -> String {
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).json"
        try JSONEncoder().encode(command).write(to: requests.appending(path: name), options: .atomic)
        return name
    }

    /// Waits for the reply to request `name`, woken by the replies folder
    /// changing rather than a poll, and on no reply takes the request back.
    func reply(to name: String, timeout: Duration) async throws -> TestHookReply {
        let files = FileManager.default
        let request = requests.appending(path: name)
        let reply = replies.appending(path: name)
        try? files.createDirectory(at: replies, withIntermediateDirectories: true)
        let folder = open(replies.path, O_EVTONLY)
        guard folder >= 0 else {
            try? files.removeItem(at: request)
            throw CocoaError(.fileReadNoPermission)
        }
        let queue = DispatchQueue(label: "dev.jparker.lexicon.test-hooks.reply")
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: queue)
        // Every way the wait ends cancels the source, and its cancel handler runs
        // once: it reads the reply a last time, so one that landed by the deadline
        // counts however late this task wakes. The deadline is a Dispatch timer for
        // the same reason: under load a task can wake long after it asked to.
        let data: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                source.setCancelHandler {
                    close(folder)
                    continuation.resume(returning: try? Data(contentsOf: reply))
                }
                source.setEventHandler { if FileManager.default.fileExists(atPath: reply.path) { source.cancel() } }
                source.resume()
                // Dispatch registers the source before `queue` runs anything queued after
                // resume(), so this check runs with the watch live: a reply is either
                // here now or raises an event.
                queue.async { if FileManager.default.fileExists(atPath: reply.path) { source.cancel() } }
                queue.asyncAfter(deadline: .now() + timeout / .seconds(1)) { source.cancel() }
            }
        } onCancel: {
            source.cancel()
        }
        guard let data else {
            try? files.removeItem(at: request)
            throw TestHookError.noReply
        }
        try? files.removeItem(at: reply)
        return try JSONDecoder().decode(TestHookReply.self, from: data)
    }
}

/// App side: watches the requests folder and answers each request once. Keep it
/// alive for as long as hooks should answer.
public final class TestHookServer {
    let source: any DispatchSourceFileSystemObject

    /// `handle` runs once per request, off the main actor; hop to it for AppKit.
    public init(channel: TestHookChannel,
                handle: @escaping @Sendable (TestHookCommand) async -> TestHookReply) throws {
        let files = FileManager.default
        try files.createDirectory(at: channel.requests, withIntermediateDirectories: true)
        try files.createDirectory(at: channel.replies, withIntermediateDirectories: true)
        // Replies left by an earlier launch have no one waiting for them.
        for name in (try? files.contentsOfDirectory(atPath: channel.replies.path)) ?? [] {
            try? files.removeItem(at: channel.replies.appending(path: name))
        }

        let folder = open(channel.requests.path, O_EVTONLY)
        guard folder >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let queue = DispatchQueue(label: "dev.jparker.lexicon.test-hooks")
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: queue)
        source.setEventHandler { Self.drain(channel, handle) }
        source.setCancelHandler { close(folder) }
        source.resume()
        // Requests written before the watch started raise no event. Dispatch
        // registers the source before `queue` runs anything queued after resume(),
        // so this drain runs with the watch live: once init returns, the server
        // has seen or will see every request, whenever it was written.
        queue.sync { Self.drain(channel, handle) }
    }

    deinit { source.cancel() }

    /// Runs on the server's serial queue only. Each request file is deleted
    /// before it is handled, so no request is handled twice.
    static func drain(_ channel: TestHookChannel,
                      _ handle: @escaping @Sendable (TestHookCommand) async -> TestHookReply) {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: channel.requests.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let request = channel.requests.appending(path: name)
            let written = (try? files.attributesOfItem(atPath: request.path)[.modificationDate]) as? Date
            guard let data = try? Data(contentsOf: request) else { continue }
            try? files.removeItem(at: request)
            if let written, -written.timeIntervalSinceNow > TestHookChannel.staleAfter { continue }

            let reply = channel.replies.appending(path: name)
            guard let command = try? JSONDecoder().decode(TestHookCommand.self, from: data) else {
                write(.failed("not a test hook command"), to: reply)
                continue
            }
            Task { write(await handle(command), to: reply) }
        }
    }

    static func write(_ reply: TestHookReply, to url: URL) {
        try? JSONEncoder().encode(reply).write(to: url, options: .atomic)
    }
}
#endif
