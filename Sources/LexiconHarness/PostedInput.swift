#if DEBUG
import Foundation
import IOKit

/// The windows a check posts input in, for `scripts/live-lane.sh idle`. The
/// keys and clicks a check posts (History's own, and Dev's Cmd-V after a paste
/// or a Dictation) reset the Mac's idle time as Jake's would, so a second run
/// read its own keys as Jake at the keyboard and waited them out. Each window
/// is one line, "from to idle" in seconds since 1970, with the idle time read
/// as it began, so `idle` can step back over it to the input before.
enum PostedInput {
    /// Runs `body` as one window. A body that throws still posted, so it is noted too.
    static func during<T>(_ body: () async throws -> T) async rethrows -> T {
        let from = Date().timeIntervalSince1970
        let idle = idleSeconds()
        defer { if let idle { note(from: from, idle: idle) } }
        return try await body()
    }

    /// Where live-lane.sh reads them: its state folder in Lexicon Dev's data.
    /// HOME as the shell has it, so a test's fake HOME holds its own.
    static var file: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/Application Support/Lexicon Dev/live-lane/posted-input.tsv")
    }

    /// IOHIDSystem's HIDIdleTime in seconds, the reading `idle` takes.
    static func idleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
    }

    /// Appends one window, keeping the newest 50: `idle` only ever steps back a few.
    static func note(from: Double, idle: Double) {
        let line = String(format: "%.3f\t%.3f\t%.3f", from, Date().timeIntervalSince1970, idle)
        let kept = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").suffix(49)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (kept + [Substring(line)]).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
#endif
