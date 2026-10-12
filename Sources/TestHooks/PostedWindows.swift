#if DEBUG
public import Foundation

// The pure half of the harness's posted-input windows: where they live, one
// line's format and the append. Here rather than in the harness so tests can
// reach it; the harness reads the idle time and times each window.

/// The windows a check posts input in, for `scripts/live-lane.sh idle`. The
/// keys and clicks a check posts (History's own, and Dev's Cmd-V after a paste
/// or a Dictation) reset the Mac's idle time as Jake's would, so a second run
/// read its own keys as Jake at the keyboard and waited them out. Each window
/// is one line, "from to idle" in seconds since 1970, with the idle time read
/// as it began, so `idle` can step back over it to the input before.
public enum PostedWindows {
    /// In live-lane.sh's state folder in Lexicon Dev's data.
    public static func file(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Lexicon Dev/live-lane/posted-input.tsv")
    }

    public static func line(from: Double, to: Double, idle: Double) -> String {
        String(format: "%.3f\t%.3f\t%.3f\n", from, to, idle)
    }

    /// One write in append mode, so two checks at once can't lose each other's
    /// line. The harness is the file's only writer and never trims it (about
    /// 40 bytes a window); `idle` reads only the newest 50.
    public static func append(_ line: String, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }
}
#endif
