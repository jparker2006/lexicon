#if DEBUG
import Foundation
import IOKit
import TestHooks

/// Times each window a check posts input in and notes it in `PostedWindows`'
/// file, which `scripts/live-lane.sh idle` skips.
enum PostedInput {
    /// Runs `body` as one window. A body that throws still posted, so it is noted too.
    static func during<T>(_ body: () async throws -> T) async rethrows -> T {
        let from = Date().timeIntervalSince1970
        let idle = idleSeconds()
        defer {
            if let idle { PostedWindows.append(PostedWindows.line(from: from, to: Date().timeIntervalSince1970, idle: idle), to: file) }
        }
        return try await body()
    }

    /// HOME as the shell has it, so a test's fake HOME holds its own.
    static var file: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return PostedWindows.file(home: home)
    }

    /// IOHIDSystem's HIDIdleTime in seconds, the reading `idle` takes.
    static func idleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
    }
}
#endif
