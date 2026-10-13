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
    /// the window before it. So every window whose samples are all captured is
    /// still needed when the clip ends, whatever its length.
    public func starts(total: Int) -> [Int] {
        guard total > 0 else { return [] }
        return [0] + Swift.stride(from: stride, to: total - overlap, by: stride)
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

/// A model that reads long audio in `grid`'s windows. Each window is decoded
/// as soon as its last sample is captured, one after another, so fn-up waits
/// only for the window still open, any window whose decode failed, and the
/// join. A clip of one window or less is decoded at fn-up, as a whole clip
/// always was.
///
/// Holds only the audio of windows not yet decoded (about two windows while
/// decoding keeps up; more while a first load compiles), never the whole
/// Dictation: the clip is the RAM copy.
public final class WindowedSession<Window: Sendable>: LocalSession {
    let grid: WindowGrid
    let decode: @Sendable (_ samples: [Int16], _ start: Int) async throws -> Window
    let join: @Sendable ([Window]) async throws -> String

    private struct State {
        /// Captured audio from sample `heldFrom` on.
        var held: [Int16] = []
        var heldFrom = 0
        /// The next window to decode while recording, by its place in the grid.
        var next = 0
        /// Windows decoded while recording, by their place in the grid. One that
        /// failed is missing, and `finish` decodes it again from the clip.
        var decoded: [Int: Window] = [:]
        /// Decodes the captured windows in order; nil while none is ready.
        var worker: Task<Void, Never>?
        /// fn-up or cancel: no more audio is taken.
        var closed = false
    }
    private let state = Mutex(State())

    /// `decode` reads one window that starts at sample `start` of the clip;
    /// `join` makes the clip's text from its windows, in order.
    public init(grid: WindowGrid, decode: @escaping @Sendable (_ samples: [Int16], _ start: Int) async throws -> Window,
                join: @escaping @Sendable ([Window]) async throws -> String) {
        self.grid = grid
        self.decode = decode
        self.join = join
    }

    public func append(_ samples: [Int16]) {
        state.withLock { state in
            guard !state.closed else { return }
            state.held += samples
            if state.worker == nil, nextWindow(state) != nil {
                state.worker = Task { await self.decodeCaptured() }
            }
        }
    }

    /// The next window to decode while recording, if all its samples are in.
    private func nextWindow(_ state: State) -> (start: Int, samples: ArraySlice<Int16>)? {
        let start = state.next * grid.stride
        let offset = start - state.heldFrom
        guard !state.closed, state.held.count - offset >= grid.window else { return nil }
        return (start, state.held[offset..<offset + grid.window])
    }

    private func decodeCaptured() async {
        while let (start, samples) = state.withLock({ state in
            let next = nextWindow(state)
            if next == nil { state.worker = nil }
            return next.map { ($0.start, Array($0.samples)) }
        }) {
            // A window that fails is not the Dictation's answer: the clip is whole at
            // fn-up, and `finish` decodes that one window again from it.
            let window = try? await decode(samples, start)
            state.withLock { state in
                state.decoded[state.next] = window
                state.next += 1
                // The next window starts one stride on: what comes before it is done with.
                let next = state.next * grid.stride
                state.held.removeFirst(min(next - state.heldFrom, state.held.count))
                state.heldFrom = next
            }
        }
    }

    public func finish(_ clip: AudioClip) async throws -> String {
        let worker = state.withLock { state in
            state.closed = true
            return state.worker
        }
        await worker?.value
        let decoded = state.withLock { state in
            defer { state.held = [] }
            return state.decoded
        }
        // Every window decoded while recording is in the clip's grid too; the rest come from the clip.
        var windows: [Window] = []
        for (place, start) in grid.starts(total: clip.samples.count).enumerated() {
            if let window = decoded[place] {
                windows.append(window)
            } else {
                let end = min(start + grid.window, clip.samples.count)
                windows.append(try await decode(Array(clip.samples[start..<end]), start))
            }
        }
        return try await join(windows)
    }

    public func cancel() {
        let worker = state.withLock { state in
            state.closed = true
            state.held = []
            return state.worker
        }
        worker?.cancel()
    }
}
