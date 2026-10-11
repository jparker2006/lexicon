import AVFAudio
import Foundation
import Synchronization
import LexiconDomain

/// Stands in for the Core Audio IO thread when the input is a file: its own
/// thread reads 512-frame blocks at the file's rate, mixes them to mono and
/// pushes them into the ring. From the ring on, a file runs the exact path the
/// mic uses (converter, CAF writer, feed).
///
/// `@unchecked Sendable`: `file` is read only by the reader thread once `start`
/// runs; every other stored property is immutable, atomic or a semaphore.
final class FileSource: @unchecked Sendable {
    static let blockFrames: AVAudioFrameCount = 512

    let sampleRate: Double
    private let file: AVAudioFile
    private let pace: FilePace
    private let stopRequested = Atomic<Bool>(false)
    /// Wakes a paced sleep early when stop is requested.
    private let wake = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private let started = Atomic<Bool>(false)

    init(url: URL, pace: FilePace) throws(RecorderError) {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.channelCount > 0, file.processingFormat.sampleRate > 0
        else { throw .unreadableFile(url) }
        self.file = file
        self.pace = pace
        sampleRate = file.processingFormat.sampleRate
    }

    /// `firstAudio` runs once, when the first block enters the ring. `ended`
    /// runs once when the thread exits: the time the last sample was read, or
    /// nil if stopped before the end of the file.
    func start(into ring: SPSCRing, firstAudio: @escaping @Sendable (HostTime) -> Void,
               ended: @escaping @Sendable (HostTime?) -> Void) {
        started.store(true, ordering: .relaxed)
        let thread = Thread { [self] in
            ended(run(into: ring, firstAudio: firstAudio))
            exited.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.name = "lexicon.audio.file"
        thread.start()
    }

    /// Waits for the reader thread to exit, so nothing writes the ring after.
    /// The thread checks for stop at every 512-frame block, so this is one block
    /// read at most; the deadline only guards against a file read that hangs.
    /// Call at most once.
    func stop() {
        guard started.load(ordering: .relaxed) else { return }
        stopRequested.store(true, ordering: .relaxed)
        wake.signal()
        _ = exited.wait(timeout: .now() + .seconds(1))
    }

    private var stopping: Bool { stopRequested.load(ordering: .relaxed) }

    private func run(into ring: SPSCRing, firstAudio: (HostTime) -> Void) -> HostTime? {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.blockFrames) else { return nil }
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: Int(Self.blockFrames))
        let began = DispatchTime.now()
        var framesRead = 0

        while !stopping {
            guard (try? file.read(into: buffer, frameCount: Self.blockFrames)) != nil else { return nil }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return HostTime.now() }
            let data = buffer.floatChannelData!
            if channels > 1 {
                for frame in 0..<count {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[channel][frame] }
                    mono[frame] = sum / Float(channels)
                }
            }
            let pushed = mono.withUnsafeBufferPointer { mixed in
                let block = channels > 1 ? UnsafeBufferPointer(rebasing: mixed[0..<count])
                                         : UnsafeBufferPointer(start: data[0], count: count)
                return push(block, into: ring)
            }
            guard pushed else { return nil }
            if framesRead == 0 { firstAudio(HostTime.now()) }
            framesRead += count
            // The end is the end even if a stop arrives during the last paced sleep.
            if file.framePosition >= file.length { return HostTime.now() }
            if pace == .realtime, !stopping {
                let due = began + .nanoseconds(Int(Double(framesRead) / sampleRate * 1e9))
                _ = wake.wait(timeout: due)
            }
        }
        return nil
    }

    /// Unlike the mic, a file can wait for room instead of dropping frames.
    /// False if a stop cut the block short.
    private func push(_ block: UnsafeBufferPointer<Float>, into ring: SPSCRing) -> Bool {
        var offset = 0
        while offset < block.count, !stopping {
            offset += ring.write(UnsafeBufferPointer(rebasing: block[offset...]))
            if offset < block.count { _ = wake.wait(timeout: .now() + .milliseconds(2)) }
        }
        return offset == block.count
    }
}
