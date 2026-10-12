import AVFAudio
import Foundation
import os
import LexiconDomain

/// Internal shared state of one LiveCapture. Everything below `queue` is
/// confined to the writer queue; the rings are the only thing the producer touches.
///
/// Each drain: ring -> converter -> RAM copy -> `AudioFileWritePackets` -> feed.
/// A chunk is yielded only after it was handed to the file, so anything a
/// consumer sees survives an app crash. F_FULLFSYNC every `fullSyncEvery`.
/// Under 1 GB free, or on a write error, the capture carries on in RAM.
///
/// `@unchecked Sendable`: every `var` is touched only on `queue` (all entry
/// points dispatch onto it), except `tailLength` (see there); the `let`s are
/// immutable or thread-safe themselves.
final class CaptureCore: @unchecked Sendable {
    let feed: AudioFeed
    let signals: CaptureSignals
    let source: any CaptureSource

    private let feedContinuation: AudioFeed.Continuation
    private let problems: AsyncStream<CaptureProblem>.Continuation
    private let queue: DispatchQueue
    private let policy: FlushPolicy
    private let fileURL: URL
    /// fn-down, for the start gap.
    private let startedAt: HostTime
    /// One level per emitted chunk, for the recording indicator.
    private let onLevel: @Sendable (AudioLevel) -> Void

    private var segment: Segment
    private var resampler: Resampler
    private var writer: CAFWriter?
    private var storage: AudioStorage = .onDisk
    private var samples: [Int16] = []
    private var chunkIndex = 0
    private var lastFullSync = DispatchTime.now()
    private var timer: (any DispatchSourceTimer)?
    private var tailTimer: (any DispatchSourceTimer)?
    private var tail = Tail()
    /// Samples captured before fn-up, once it came.
    private var heardBeforeRelease: Int?
    private var take: Take?
    /// `.noFrames` until frames come, `.zeros` while every one is 0, then `.real` for good.
    private var sound: InputSound = .noFrames
    /// Audio refused by rings already left behind by a device change.
    private var droppedEarlier: Duration = .zero
    /// Audio kept after fn-up. Set by `finish` on the writer queue; read only
    /// after `stop` returned, which orders it after the write.
    private(set) var tailLength: Duration?
    #if DEBUG
    /// Every frame read as zero (the `mic zeros` test hook). Set before `begin`.
    var silenced = false
    #endif

    init?(source: any CaptureSource, file: URL, policy: FlushPolicy, queue: DispatchQueue, startedAt: HostTime,
          onLevel: @escaping @Sendable (AudioLevel) -> Void) {
        segment = source.firstSegment
        guard let resampler = Self.resampler(for: segment.rate, policy: policy) else { return nil }
        self.resampler = resampler
        self.source = source
        self.queue = queue
        self.policy = policy
        self.startedAt = startedAt
        self.onLevel = onLevel
        fileURL = file
        (feed, feedContinuation) = AudioFeed.makeStream()
        let (problemStream, problems) = AsyncStream<CaptureProblem>.makeStream()
        self.problems = problems
        signals = CaptureSignals(first: OneShot(), end: OneShot(), problems: problemStream)
        samples.reserveCapacity(PCM16k.sampleRate * 30)
    }

    /// Creates the file and the drain timer on the writer queue, and starts the
    /// producer meanwhile: the file never stands in front of the first audio
    /// (the ring holds it), and is queued before anything the producer reports.
    func begin() {
        defer {
            let (first, end) = (signals.first, signals.end)
            source.start(SourceEvents(firstAudio: { first.settle($0) }, ended: { end.settle($0) },
                                      switched: { [weak self] in self?.switchSegment(to: $0) }))
        }
        queue.async { [self] in
            if hasRoom() {
                do {
                    writer = try CAFWriter(creating: fileURL)
                } catch {
                    diskTrouble()
                }
            } else {
                diskTrouble()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + policy.drainEvery.dispatch, repeating: policy.drainEvery.dispatch,
                           leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// `.released`: capture the adaptive tail first (`Tail`), then stop.
    func stop(_ ending: Ending) async -> Take {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let done = { [self] in
                    continuation.resume(returning: finish())
                    closeFile()
                }
                if case .released(let at) = ending, take == nil {
                    captureTail(releasedAt: at, then: done)
                } else {
                    done()
                }
            }
        }
    }

    /// The LiveCapture went away without `stop`: stop anyway, keeping the audio.
    func dropped() {
        queue.async { [self] in
            guard take == nil else { return }
            _ = finish()
            closeFile()
        }
    }

    // MARK: Writer queue

    private func tick() {
        guard take == nil else { return }
        drain()
        if DispatchTime.now() >= lastFullSync + policy.fullSyncEvery.dispatch {
            writer?.fullSync()
            lastFullSync = .now()
        }
    }

    /// Everything in the ring now was said before fn-up. After it, drain every
    /// 10 ms until the tail is over, the input ends (end of file, or a new
    /// fn-down took the mic), or a stalled device runs past the cap.
    private func captureTail(releasedAt: HostTime, then done: @escaping () -> Void) {
        drain()
        heardBeforeRelease = samples.count
        let late = HostTime.now().duration(since: releasedAt)
        // Input over, or fn-up a full cap ago: what is captured is all there is,
        // the converter's last few ms included, so no tail may cut any of it.
        guard !signals.end.isSettled, late < tail.cap else { return done() }
        tail.release(late: late)
        // The cap plus one late buffer, counted from fn-up.
        let backstop = DispatchTime.now() + (tail.cap - late + .milliseconds(20)).dispatch
        let over = { [self] in tail.isOver || signals.end.isSettled || DispatchTime.now() >= backstop }
        guard !over() else { return done() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [self] in
            drain()
            guard over() else { return }
            tailTimer?.cancel()
            tailTimer = nil
            done()
        }
        tailTimer = timer
        timer.resume()
    }

    /// Idempotent: a second call returns the first Take.
    private func finish() -> Take {
        if let take { return take }
        timer?.cancel()
        timer = nil
        source.stop()  // whatever it writes after this is never read
        drain()
        resampler.flush(emit: emit)
        feedContinuation.finish()
        problems.finish()
        signals.first.settle(nil)
        signals.end.settle(nil)
        let take = Take(clip: AudioClip(samples: samples), summary: summary(), sound: sound)
        self.take = take
        tailLength = heardBeforeRelease.map { .milliseconds((samples.count - $0) * 1_000 / PCM16k.sampleRate) }
        log(take.summary)
        return take
    }

    private func summary() -> AudioSummary {
        AudioSummary(duration: AudioClip(samples: samples).duration,
                     startGap: signals.first.current.map { $0.duration(since: startedAt) },
                     deviceName: source.deviceName, storage: storage, gaps: source.gaps)
    }

    /// One line per Dictation, so the start gap and the tail are numbers in the log (#4).
    private func log(_ summary: AudioSummary) {
        Self.log.notice("""
            captured \(summary.duration.ms, privacy: .public) ms, start gap \(summary.startGap?.ms ?? -1, privacy: .public) ms, \
            tail \(self.tailLength?.ms ?? -1, privacy: .public) ms, \(summary.gaps.count, privacy: .public) device changes, \
            \(summary.storage.rawValue, privacy: .public), \((self.droppedEarlier + self.segment.droppedAudio).ms, privacy: .public) ms dropped, \
            sound \(String(describing: self.sound), privacy: .public)
            """)
    }

    /// A device change rebuilt the mic's engine: the old ring gets no more
    /// frames. Drain it at its own rate, then go on from the new ring at its
    /// rate, into the same file.
    private func switchSegment(to next: Segment) {
        queue.async { [self] in
            // A valid hardware rate always has a converter; without one the new ring is never read.
            guard take == nil, let converter = Self.resampler(for: next.rate, policy: policy) else { return }
            drain()
            resampler.flush(emit: emit)
            droppedEarlier += segment.droppedAudio
            resampler = converter
            segment = next
            problems.yield(.deviceChanged)
        }
    }

    private func closeFile() {
        writer?.close()
        writer = nil
    }

    private func drain() {
        let input = resampler.input
        let capacity = Int(input.frameCapacity)
        while true {
            let count = segment.ring.read(into: UnsafeMutableBufferPointer(start: input.floatChannelData![0], count: capacity))
            guard count > 0 else { return }
            #if DEBUG
            if silenced { input.floatChannelData![0].update(repeating: 0, count: count) }
            #endif
            // The first non-zero frame settles it as `.real`, then this is one compare per read.
            // Until then (a dead mic, or one that starts with zeros) each read is scanned, here on
            // the writer queue.
            if sound != .real {
                let frames = UnsafeBufferPointer(start: input.floatChannelData![0], count: count)
                sound = frames.contains { $0 != 0 } ? .real : .zeros
            }
            input.frameLength = AVAudioFrameCount(count)
            resampler.convert(emit: emit)
        }
    }

    private func emit(_ converted: UnsafeBufferPointer<Int16>) {
        let chunk = UnsafeBufferPointer(rebasing: converted[0..<tail.keep(converted)])
        guard !chunk.isEmpty else { return }
        onLevel(AudioLevel(rms: Self.rms(of: chunk)))
        samples.append(contentsOf: chunk)
        if let writer {
            do {
                try writer.write(chunk)
            } catch {
                diskTrouble()
            }
        }
        feedContinuation.yield(PCMChunk(index: chunkIndex, samples: Array(chunk)))
        chunkIndex += 1
    }

    /// Under 1 GB free (#4), asked of the nearest folder that exists (the audio
    /// folder may not yet). Unknown counts as room: a failed write still falls back.
    private func hasRoom() -> Bool {
        var folder = fileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder.deleteLastPathComponent()
        }
        let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return (free ?? .max) >= policy.minimumFreeBytes
    }

    /// Under 1 GB free or a write failed: continue in RAM only (#4). What is
    /// already in the file stays there, closed, for whatever it is worth.
    private func diskTrouble() {
        closeFile()
        guard storage != .ramOnly else { return }
        storage = .ramOnly
        problems.yield(.diskTrouble)
    }

    /// Full-scale RMS (0...1) of one chunk. Runs here on the writer queue, never on
    /// the audio thread, and is one pass over the samples with no allocation.
    private static func rms(of chunk: UnsafeBufferPointer<Int16>) -> Float {
        var energy: Float = 0
        for sample in chunk {
            let scaled = Float(sample) / 32_768
            energy += scaled * scaled
        }
        return (energy / Float(chunk.count)).squareRoot()
    }

    private static func resampler(for rate: Double, policy: FlushPolicy) -> Resampler? {
        let chunkFrames = AVAudioFrameCount(rate * (policy.chunk / .seconds(1)))
        return Resampler(inputRate: rate, maxFrames: max(chunkFrames, FileSource.blockFrames))
    }

    private static let log = Logger(subsystem: "Lexicon", category: "audio")
}

private extension Duration {
    var dispatch: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
