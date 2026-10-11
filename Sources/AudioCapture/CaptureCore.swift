import AVFAudio
import Foundation
import LexiconDomain

/// Internal shared state of one LiveCapture. Everything below `queue` is
/// confined to the writer queue; the ring is the only thing the producer touches.
///
/// Each drain: ring -> converter -> RAM copy -> `AudioFileWritePackets` -> feed.
/// A chunk is yielded only after it was handed to the file, so anything a
/// consumer sees survives an app crash. F_FULLFSYNC every `fullSyncEvery`.
/// On a write error the file is closed and the capture carries on in RAM.
final class CaptureCore: @unchecked Sendable {
    let feed: AudioFeed
    let signals: CaptureSignals

    private let feedContinuation: AudioFeed.Continuation
    private let problems: AsyncStream<CaptureProblem>.Continuation
    private let queue: DispatchQueue
    private let policy: FlushPolicy
    private let source: FileSource
    private let ring: SPSCRing
    private let resampler: Resampler
    private let fileURL: URL
    private let startedAt = HostTime.now()

    private var writer: CAFWriter?
    private var storage: AudioStorage = .onDisk
    private var samples: [Int16] = []
    private var chunkIndex = 0
    private var lastFullSync = DispatchTime.now()
    private var timer: (any DispatchSourceTimer)?
    private var take: Take?

    init?(source: FileSource, file: URL, policy: FlushPolicy, queue: DispatchQueue) {
        let rate = source.sampleRate
        let chunkFrames = AVAudioFrameCount(rate * (policy.chunk / .seconds(1)))
        guard let resampler = Resampler(inputRate: rate, maxFrames: max(chunkFrames, FileSource.blockFrames)) else { return nil }
        self.resampler = resampler
        self.source = source
        self.queue = queue
        self.policy = policy
        fileURL = file
        ring = SPSCRing(capacityFrames: Int(rate * 2))
        (feed, feedContinuation) = AudioFeed.makeStream()
        let (problemStream, problems) = AsyncStream<CaptureProblem>.makeStream()
        self.problems = problems
        signals = CaptureSignals(first: OneShot(), end: OneShot(), problems: problemStream)
        samples.reserveCapacity(PCM16k.sampleRate * 30)
    }

    /// Starts the producer first, then creates the file and the drain timer on
    /// the writer queue, so the file never stands in front of the first audio.
    func begin() {
        let first = signals.first
        source.start(into: ring, firstAudio: { first.settle($0) }, ended: { [signals] in signals.end.settle($0) })
        queue.async { [self] in
            do {
                writer = try CAFWriter(creating: fileURL)
            } catch {
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

    func stop() async -> Take {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: finish())
                closeFile()
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

    /// Idempotent: a second call returns the first Take.
    private func finish() -> Take {
        if let take { return take }
        timer?.cancel()
        timer = nil
        source.stop()  // the producer has exited: nothing writes the ring after this
        drain()
        resampler.flush(emit: emit)
        feedContinuation.finish()
        problems.finish()
        signals.first.settle(nil)
        signals.end.settle(nil)
        let take = Take(clip: AudioClip(samples: samples), summary: summary())
        self.take = take
        return take
    }

    private func summary() -> AudioSummary {
        AudioSummary(duration: AudioClip(samples: samples).duration,
                     startGap: signals.first.current.map { $0.duration(since: startedAt) },
                     deviceName: nil, storage: storage, gaps: [])
    }

    private func closeFile() {
        writer?.close()
        writer = nil
    }

    private func drain() {
        let input = resampler.input
        let capacity = Int(input.frameCapacity)
        while true {
            let count = ring.read(into: UnsafeMutableBufferPointer(start: input.floatChannelData![0], count: capacity))
            guard count > 0 else { return }
            input.frameLength = AVAudioFrameCount(count)
            resampler.convert(emit: emit)
        }
    }

    private func emit(_ chunk: UnsafeBufferPointer<Int16>) {
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

    /// Under 1 GB free or a write failed: continue in RAM only (#4). What is
    /// already in the file stays there, closed, for whatever it is worth.
    private func diskTrouble() {
        closeFile()
        guard storage != .ramOnly else { return }
        storage = .ramOnly
        problems.yield(.diskTrouble)
    }
}

private extension Duration {
    var dispatch: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
