import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import AudioCapture
import LexiconDomain

@Test(.timeLimit(.minutes(1)))
func writerFloorStopKeepsLowSpaceResultWhenStopWinsWriterQueue() async throws {
    let result = try await writerFloorStopScenario(rate: 16_000)

    #expect(result.take.summary.storage == .ramOnly)
    #expect(result.problems == [.diskTrouble])
    #expect(result.take.clip.samples == result.inputSamples)
    #expect(!result.beforeFlush.isEmpty)
    #expect(Array(result.take.clip.samples.prefix(result.onDisk.count)) == result.onDisk)
    #expect(CAFFile.state(of: result.file) == .closed)
}

@Test(.timeLimit(.minutes(1)))
func writerFloorStopDoesNotWriteKnownBufferedFlushAfterLowSpaceResult() async throws {
    let result = try await writerFloorStopScenario(rate: 48_000)

    #expect(result.take.summary.storage == .ramOnly)
    #expect(result.problems == [.diskTrouble])
    #expect(abs(result.take.clip.samples.count - 16_000) <= 16)
    #expect(result.take.clip.samples.count > result.beforeFlush.count)
    #expect(Array(result.take.clip.samples.prefix(result.beforeFlush.count)) == result.beforeFlush)
    #expect(result.onDisk == result.beforeFlush)
    #expect(CAFFile.state(of: result.file) == .closed)
}

private struct WriterFloorStopResult: Sendable {
    let inputSamples: [Int16]
    let beforeFlush: [Int16]
    let onDisk: [Int16]
    let file: URL
    let take: Take
    let problems: [CaptureProblem]
}

private func writerFloorStopScenario(rate: Int) async throws -> WriterFloorStopResult {
    let dir = try scratchDirectory()
    let firstFolder = dir.appending(path: "first")
    let secondFolder = dir.appending(path: "second")
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let source = syntheticSamples(count: rate)
    let wav = try writeWAV(source, rate: rate, in: dir)
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
    let firstCapture = Task { () throws -> Take in
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
    let beforeFlush = try CAFFile.read(firstURL).samples
    order.releaseFlush()

    let take = try await firstCapture.value
    await recorder.settle()

    var problems: [CaptureProblem] = []
    for await problem in signals.problems { problems.append(problem) }

    return WriterFloorStopResult(inputSamples: source, beforeFlush: beforeFlush,
                                 onDisk: try CAFFile.read(firstURL).samples,
                                 file: firstURL, take: take, problems: problems)
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

@Test(.timeLimit(.minutes(1)))
func writerFloorStopReturnsBeforePendingSpaceReadAndKeepsItsSnapshot() async throws {
    let dir = try scratchDirectory()
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/pending-space.caf")
    let gate = WriterPendingSpace()
    var policy = FlushPolicy()
    policy.fullSyncEvery = .zero
    policy.files.freeBytes = { [gate] _, floor in gate.freeBytes(floor: floor) }
    policy.files.sync = { [gate] _ in gate.signalSyncComplete(); return true }

    let recorder = Recorder(policy: policy)
    let stop = WriterPendingStop()
    let captureTask = Task { () throws -> Take in
        let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
        stop.captureStarted(capture.signals)
        await stop.waitForStopRequest()
        return await capture.stop(.immediately)
    }
    defer {
        stop.requestStop()
        gate.release()
    }

    let signals = try #require(await writerFloorStopNext(stop.started))
    _ = try #require(await writerFloorStopNext(gate.readEntered))
    _ = try #require(await signals.inputEnded())
    stop.requestStop()
    let take = try await captureTask.value

    // The stop returned while the free-space read remained held.
    let frozenSummary = take.summary
    let frozenSamples = take.clip.samples
    #expect(take.summary.storage == .onDisk)
    gate.release()
    _ = try #require(await writerFloorStopNext(gate.syncCompleted))
    await recorder.settle()

    #expect(take.summary == frozenSummary)
    #expect(take.clip.samples == frozenSamples)
    let problems = await writerFloorStopProblems(signals)
    #expect(problems.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func writerFloorStopReturnsBeforePendingSyncFailureAndKeepsItsSnapshot() async throws {
    let dir = try scratchDirectory()
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/pending-sync.caf")
    let gate = WriterPendingSync()
    var policy = FlushPolicy()
    policy.fullSyncEvery = .zero
    policy.files.sync = { [gate] _ in gate.sync() }

    let recorder = Recorder(policy: policy)
    let stop = WriterPendingStop()
    let captureTask = Task { () throws -> Take in
        let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
        stop.captureStarted(capture.signals)
        await stop.waitForStopRequest()
        return await capture.stop(.immediately)
    }
    defer {
        stop.requestStop()
        gate.release()
    }

    let signals = try #require(await writerFloorStopNext(stop.started))
    _ = try #require(await writerFloorStopNext(gate.firstSyncEntered))
    _ = try #require(await signals.inputEnded())
    stop.requestStop()
    let take = try await captureTask.value

    // The stop returned while the failed sync remained held.
    let frozenSummary = take.summary
    let frozenSamples = take.clip.samples
    #expect(take.summary.storage == .onDisk)
    gate.release()
    _ = try #require(await writerFloorStopNext(gate.laterSyncCompleted))
    await recorder.settle()

    #expect(take.summary == frozenSummary)
    #expect(take.clip.samples == frozenSamples)
    let problems = await writerFloorStopProblems(signals)
    #expect(problems.isEmpty)
}

private final class WriterPendingStop: Sendable {
    private let startedContinuation: AsyncStream<CaptureSignals>.Continuation
    let started: AsyncStream<CaptureSignals>
    private let requestContinuation: AsyncStream<Void>.Continuation
    private let request: AsyncStream<Void>

    init() {
        (started, startedContinuation) = AsyncStream.makeStream()
        (request, requestContinuation) = AsyncStream.makeStream()
    }

    func captureStarted(_ signals: CaptureSignals) { startedContinuation.yield(signals) }
    func requestStop() { requestContinuation.yield(()) }

    func waitForStopRequest() async {
        var iterator = request.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private final class WriterPendingSpace: Sendable {
    private let reads = Mutex(0)
    private let readGate = DispatchSemaphore(value: 0)
    private let readContinuation: AsyncStream<Void>.Continuation
    let readEntered: AsyncStream<Void>
    private let syncContinuation: AsyncStream<Void>.Continuation
    let syncCompleted: AsyncStream<Void>

    init() {
        (readEntered, readContinuation) = AsyncStream.makeStream()
        (syncCompleted, syncContinuation) = AsyncStream.makeStream()
    }

    func freeBytes(floor: Int64) -> Int64? {
        let read = reads.withLock { count -> Int in
            count += 1
            return count
        }
        guard read == 2 else { return floor + 1 }
        readContinuation.yield(())
        readGate.wait()
        return floor - 1
    }

    func signalSyncComplete() { syncContinuation.yield(()) }
    func release() { readGate.signal() }
}

private final class WriterPendingSync: Sendable {
    private let calls = Mutex(0)
    private let syncGate = DispatchSemaphore(value: 0)
    private let enteredContinuation: AsyncStream<Void>.Continuation
    let firstSyncEntered: AsyncStream<Void>
    private let laterContinuation: AsyncStream<Void>.Continuation
    let laterSyncCompleted: AsyncStream<Void>

    init() {
        (firstSyncEntered, enteredContinuation) = AsyncStream.makeStream()
        (laterSyncCompleted, laterContinuation) = AsyncStream.makeStream()
    }

    func sync() -> Bool {
        let call = calls.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 {
            enteredContinuation.yield(())
            syncGate.wait()
            return false
        }
        laterContinuation.yield(())
        return true
    }

    func release() { syncGate.signal() }
}

private func writerFloorStopProblems(_ signals: CaptureSignals) async -> [CaptureProblem] {
    var problems: [CaptureProblem] = []
    for await problem in signals.problems { problems.append(problem) }
    return problems
}
