import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import AudioCapture
import LexiconDomain

@Test(.timeLimit(.minutes(1)))
func writerFloorStopKeepsLowSpaceResultWhenStopWinsWriterQueue() async throws {
    let dir = try scratchDirectory()
    let firstFolder = dir.appending(path: "first")
    let secondFolder = dir.appending(path: "second")
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let firstURL = firstFolder.appending(path: "audio/first.caf")
    let secondURL = secondFolder.appending(path: "audio/second.caf")
    let order = WriterFloorStopOrder(firstFolder: firstFolder)

    var policy = FlushPolicy()
    policy.fullSyncEvery = .zero
    policy.files.freeBytes = { [order] folder, floor in order.freeBytes(at: folder, floor: floor) }
    policy.files.sync = { [order] _ in
        order.syncEntered()
        return true
    }
    policy.convert = { [order] converter, output, input in
        order.convert(converter, output: output, input: input)
    }

    let recorder = Recorder(policy: policy)
    let firstCapture = Task { () async throws -> Take in
        let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: firstURL)
        order.firstCaptureStarted(capture.signals)
        await order.stopFirstCapture()
        return await capture.stop(.immediately)
    }
    defer {
        order.requestFirstStop()
        order.releaseCadenceRead()
        order.releaseFlush()
    }

    let signals = try #require(await writerFloorStopNext(order.firstCapture))
    _ = try #require(await writerFloorStopNext(order.cadenceRead))
    _ = try #require(await writerFloorStopNext(order.firstConverter))
    _ = try #require(await signals.inputEnded())

    // This capture's sync queues behind the held free-space read on the same
    // Recorder sync queue. Its signal proves that read's writer callback queued.
    let secondCapture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: secondURL)
    _ = await secondCapture.stop(.immediately)

    order.requestFirstStop()
    _ = try #require(await writerFloorStopNext(order.firstFlush))
    order.releaseCadenceRead()
    _ = try #require(await writerFloorStopNext(order.sync))
    order.releaseFlush()

    let take = try await firstCapture.value
    await recorder.settle()

    var problems: [CaptureProblem] = []
    for await problem in signals.problems { problems.append(problem) }

    let onDisk = try CAFFile.read(firstURL).samples
    #expect(take.summary.storage == .ramOnly)
    #expect(problems == [.diskTrouble])
    #expect(take.clip.samples == source)
    #expect(!onDisk.isEmpty)
    #expect(Array(take.clip.samples.prefix(onDisk.count)) == onDisk)
    #expect(CAFFile.state(of: firstURL) == .closed)
}

private final class WriterFloorStopOrder: Sendable {
    private let firstFolder: URL
    private let reads = Mutex(0)
    private let firstConverterID = Mutex<ObjectIdentifier?>(nil)
    private let flushStarted = Mutex(false)
    private let readGate = DispatchSemaphore(value: 0)
    private let flushGate = DispatchSemaphore(value: 0)

    private let firstCaptureContinuation: AsyncStream<CaptureSignals>.Continuation
    let firstCapture: AsyncStream<CaptureSignals>
    private let cadenceReadContinuation: AsyncStream<Void>.Continuation
    let cadenceRead: AsyncStream<Void>
    private let converterContinuation: AsyncStream<Void>.Continuation
    let firstConverter: AsyncStream<Void>
    private let flushContinuation: AsyncStream<Void>.Continuation
    let firstFlush: AsyncStream<Void>
    private let syncContinuation: AsyncStream<Void>.Continuation
    let sync: AsyncStream<Void>
    private let stopContinuation: AsyncStream<Void>.Continuation
    private let stopRequest: AsyncStream<Void>

    init(firstFolder: URL) {
        self.firstFolder = firstFolder.standardizedFileURL
        (firstCapture, firstCaptureContinuation) = AsyncStream.makeStream()
        (cadenceRead, cadenceReadContinuation) = AsyncStream.makeStream()
        (firstConverter, converterContinuation) = AsyncStream.makeStream()
        (firstFlush, flushContinuation) = AsyncStream.makeStream()
        (sync, syncContinuation) = AsyncStream.makeStream()
        (stopRequest, stopContinuation) = AsyncStream.makeStream()
    }

    func firstCaptureStarted(_ signals: CaptureSignals) {
        firstCaptureContinuation.yield(signals)
    }

    func freeBytes(at folder: URL, floor: Int64) -> Int64? {
        let path = folder.standardizedFileURL.path
        guard path == firstFolder.path || path.hasPrefix(firstFolder.path + "/") else { return floor + 1 }
        let read = reads.withLock { count -> Int in
            count += 1
            return count
        }
        guard read == 2 else { return floor + 1 }
        cadenceReadContinuation.yield(())
        readGate.wait()  // timing-ok: the test releases the held disk read during the stop flush
        return floor - 1
    }

    func convert(
        _ converter: AVAudioConverter,
        output: AVAudioPCMBuffer,
        input: @escaping AVAudioConverterInputBlock
    ) -> (AVAudioConverterOutputStatus, NSError?) {
        let id = ObjectIdentifier(converter)
        let (isFirst, newlyObserved) = firstConverterID.withLock { stored -> (Bool, Bool) in
            guard let stored else {
                stored = id
                return (true, true)
            }
            return (stored == id, false)
        }
        if newlyObserved { converterContinuation.yield(()) }

        return Resampler.realConvert(converter, output) { [self] converter, status in
            let buffer = input(converter, status)
            guard isFirst, status.pointee == .endOfStream else { return buffer }
            let shouldWait = flushStarted.withLock { started -> Bool in
                guard !started else { return false }
                started = true
                return true
            }
            if shouldWait {
                flushContinuation.yield(())
                flushGate.wait()  // timing-ok: the test releases the flush after the sync-queue marker
            }
            return buffer
        }
    }

    func syncEntered() { syncContinuation.yield(()) }
    func requestFirstStop() { stopContinuation.yield(()) }
    func releaseCadenceRead() { readGate.signal() }
    func releaseFlush() { flushGate.signal() }

    func stopFirstCapture() async {
        var iterator = stopRequest.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private func writerFloorStopNext<Value: Sendable>(_ stream: AsyncStream<Value>) async -> Value? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}
