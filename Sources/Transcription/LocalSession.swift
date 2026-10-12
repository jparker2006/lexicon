import Synchronization
public import LexiconDomain

/// How a local model reads long audio: fixed windows of `window` samples,
/// each overlapping the one before it by `overlap`, decoded on their own and
/// then joined. A window is final once all its samples are captured, so it can
/// be decoded while Jake is still talking.
public struct WindowGrid: Sendable, Hashable {
    public let window: Int
    public let overlap: Int

    public init(window: Int, overlap: Int) {
        precondition(window > 0 && overlap >= 0 && overlap < window)
        self.window = window
        self.overlap = overlap
    }

    public var stride: Int { window - overlap }

    /// Where each window of a clip of `total` samples starts. A window past the
    /// first is only needed when it reaches beyond the overlap it shares with
    /// the window before it.
    public func starts(total: Int) -> [Int] {
        // Not built yet: one window for the whole clip, as before.
        total > 0 ? [0] : []
    }
}

/// One Dictation's local transcription. `append` gets the audio as it is
/// captured; `finish` gets the whole clip (the source of truth) at fn-up and
/// returns its text. Finished or cancelled at most once.
public protocol LocalSession: Sendable {
    func append(_ samples: [Int16])
    func finish(_ clip: AudioClip) async throws -> String
    func cancel()
}

/// A model that reads a clip in one call at fn-up: nothing to do while Jake talks.
public final class WholeClipSession: LocalSession {
    let transcribe: @Sendable (AudioClip) async throws -> String

    public init(_ transcribe: @escaping @Sendable (AudioClip) async throws -> String) {
        self.transcribe = transcribe
    }

    public func append(_ samples: [Int16]) {}
    public func finish(_ clip: AudioClip) async throws -> String { try await transcribe(clip) }
    public func cancel() {}
}

/// A model that reads long audio in `grid`'s windows.
public final class WindowedSession<Window: Sendable>: LocalSession {
    let grid: WindowGrid
    let decode: @Sendable (_ samples: [Int16], _ start: Int) async throws -> Window
    let join: @Sendable ([Window]) async throws -> String

    /// `decode` reads one window that starts at sample `start` of the clip;
    /// `join` makes the clip's text from its windows, in order.
    public init(grid: WindowGrid, decode: @escaping @Sendable (_ samples: [Int16], _ start: Int) async throws -> Window,
                join: @escaping @Sendable ([Window]) async throws -> String) {
        self.grid = grid
        self.decode = decode
        self.join = join
    }

    public func append(_ samples: [Int16]) {}

    public func finish(_ clip: AudioClip) async throws -> String {
        // Not built yet: the whole clip at fn-up, as before.
        try await join(clip.samples.isEmpty ? [] : [decode(clip.samples, 0)])
    }

    public func cancel() {}
}
