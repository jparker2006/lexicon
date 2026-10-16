import Foundation
import Synchronization
import Testing
@testable import AudioCapture
import LexiconDomain

@Test func writerScheduleFirstAudioReachesDiskBeforeTimer() async throws {
    let dir = try scratchDirectory()
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/first.caf")
    let recorder = Recorder(policy: FlushPolicy(drainEvery: .seconds(60)))

    let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
    _ = try #require(await capture.signals.inputEnded())
    let onDisk = (try? CAFFile.read(caf))?.samples.count ?? 0
    #expect(onDisk > 0)

    _ = await capture.stop(.immediately)
    await recorder.settle()
}

@Test(.timeLimit(.minutes(1)))
func writerScheduleDrainsWhileSyncIsBlocked() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/slow-sync.caf")

    let blockedSync = AC2BlockedSync(caf: caf)
    var policy = FlushPolicy()
    policy.drainEvery = .milliseconds(5)
    policy.fullSyncEvery = .zero
    policy.files.sync = { _ in blockedSync.call() }

    let recorder = Recorder(policy: policy)
    let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
    defer { blockedSync.release() }

    let writtenAtSync = await ac2Next(blockedSync.entered)
    let syncEntered = writtenAtSync != nil
    #expect(syncEntered, "the periodic full sync should start while capture is open")

    // Ignore chunks already written when the sync began; only later chunks prove progress.
    let observed = syncEntered ? await ac2CollectAfter(capture.feed, written: writtenAtSync!) ?? [] : []
    #expect(observed.count >= 3, "three later chunks should arrive while sync is blocked")
    #expect(blockedSync.calls == 1, "ticks must not enter another sync while one is outstanding")

    let delivered = observed.flatMap(\.samples)
    let diskSamples = try? CAFFile.read(caf).samples
    #expect(diskSamples.map { Array($0.prefix(delivered.count)) } == delivered,
            "the on-disk prefix should match the samples already delivered to the feed")

    blockedSync.release()
    _ = await capture.stop(.immediately)
    await recorder.settle()
}

private final class AC2BlockedSync: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let count = Mutex(0)
    private let released = Mutex(false)
    private let enteredContinuation: AsyncStream<Int>.Continuation
    let entered: AsyncStream<Int>
    private let caf: URL

    init(caf: URL) {
        self.caf = caf
        (entered, enteredContinuation) = AsyncStream<Int>.makeStream()
    }

    var calls: Int { count.withLock { $0 } }

    func call() -> Bool {
        let invocation = count.withLock { count -> Int in
            count += 1
            return count
        }
        if invocation == 1 {
            enteredContinuation.yield((try? CAFFile.read(caf).samples.count) ?? 0)
            gate.wait()  // timing-ok: the fake full sync stays blocked until the test releases it
        }
        return true
    }

    func release() {
        let shouldSignal = released.withLock { released -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal { gate.signal() }
    }
}

private func ac2Next<Element: Sendable>(_ stream: AsyncStream<Element>) async -> Element? {
    await ac2WithHangBound {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

private func ac2CollectAfter(_ feed: AudioFeed, written: Int) async -> [PCMChunk]? {
    await ac2WithHangBound {
        var chunks: [PCMChunk] = []
        var received = 0
        var later = 0
        for await chunk in feed {
            chunks.append(chunk)
            received += chunk.samples.count
            if received > written { later += 1 }
            if later == 3 { return chunks }
        }
        return nil
    }
}

private func ac2WithHangBound<Value: Sendable>(
    _ operation: @escaping @Sendable () async -> Value?
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))  // timing-ok: hang bound only, so a stalled test can release sync
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@Test(.timeLimit(.minutes(1)))
func writerScheduleFinalSyncDoesNotBlockNextCaptureDrain() async throws {
    let dir = try scratchDirectory()
    let expectedFirst = syntheticSamples(count: 16_000)
    let wav = try writeWAV(expectedFirst, rate: 16_000, in: dir)
    let firstURL = dir.appending(path: "audio/first.caf")
    let secondURL = dir.appending(path: "audio/second.caf")

    let (syncEntered, syncSignal) = AsyncStream<Void>.makeStream()
    let syncGate = WriterScheduleSyncGate(entered: syncSignal)
    defer { syncGate.release() }

    var policy = FlushPolicy()
    policy.fullSyncEvery = .seconds(60)  // only the first capture's final sync runs in this test
    policy.minimumFreeBytes = 0
    policy.files.sync = { [syncGate] _ in syncGate.sync() }

    let mic = FakeMic()
    let recorder = Recorder(hardware: mic.hardware, policy: policy)
    let first = try await recorder.start(.file(wav, pace: .realtime), writingTo: firstURL)
    _ = try #require(await first.signals.inputEnded())

    // Stop closes the first CAF, then blocks in its final sync until the test opens the gate.
    let firstTake = await first.stop(.immediately)
    let didEnterSync: Void? = await writerScheduleNext(from: syncEntered, before: .seconds(3))
    #expect(didEnterSync != nil)
    guard didEnterSync != nil else {
        syncGate.release()
        await recorder.settle()
        return
    }

    let second = try await recorder.start(.microphone(deviceUID: nil), writingTo: secondURL)
    let secondChunk = await writerScheduleNext(from: second.feed, before: .seconds(3))

    // The next feed chunk was requested while the first sync was still held.
    syncGate.release()
        let secondTake = await second.stop(.immediately)
    await recorder.settle()

    #expect(secondChunk != nil, "the second capture must drain while the first sync is blocked")
    #expect(firstTake.clip.samples == expectedFirst)
    #expect(secondTake.clip.samples.count == FakeEngine.frames)
    #expect(CAFFile.state(of: firstURL) == .closed)
    #expect(CAFFile.state(of: secondURL) == .closed)
    #expect(try CAFFile.read(firstURL).samples == firstTake.clip.samples)
    #expect(try CAFFile.read(secondURL).samples == secondTake.clip.samples)
}

/// Waits for a stream event, with a cancellable deadline that only prevents a
/// broken writer queue from hanging the test. Success is determined by the event.
private func writerScheduleNext<Value: Sendable>(
    from stream: AsyncStream<Value>, before timeout: Duration
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)  // timing-ok: hang guard only; progress is an explicit stream event
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private final class WriterScheduleSyncGate: Sendable {
    private let calls = Mutex(0)
    private let entered: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)

    init(entered: AsyncStream<Void>.Continuation) {
        self.entered = entered
    }

    func sync() -> Bool {
        let first = calls.withLock { count -> Bool in
            defer { count += 1 }
            return count == 0
        }
        if first {
            entered.yield(())
            gate.wait()  // timing-ok: the test releases the final sync explicitly
        }
        return true
    }

    func release() { gate.signal() }
}

@Test(.timeLimit(.minutes(1)))
func writerScheduleSpaceFloorKeepsDiskPrefixAndWholeTake() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/space.caf")
    let space = WriterScheduleSpace()
    var policy = FlushPolicy()
    policy.fullSyncEvery = .zero
    policy.files.freeBytes = { [space] _, floor in space.bytes(floor: floor) }
    policy.files.sync = { _ in true }

    let recorder = Recorder(policy: policy)
    let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
    var feed = capture.feed.makeAsyncIterator()
    _ = try #require(await feed.next())
    space.dropBelowFloor()
    let problem = await writerScheduleNext(from: capture.signals.problems, before: .seconds(5))
    let prefixAtProblem = try CAFFile.read(caf).samples
    #expect(problem == .diskTrouble)
    #expect(!prefixAtProblem.isEmpty)

    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()
    #expect(take.summary.storage == .ramOnly)
    #expect(take.clip.samples == source)
    #expect(CAFFile.state(of: caf) == .closed)
    #expect(try CAFFile.read(caf).samples == prefixAtProblem)
    #expect(prefixAtProblem == Array(source.prefix(prefixAtProblem.count)))
}

private final class WriterScheduleSpace: Sendable {
    private let below = Mutex(false)
    func dropBelowFloor() { below.withLock { $0 = true } }
    func bytes(floor: Int64) -> Int64 { below.withLock { $0 ? floor - 1 : floor + 1 } }
}


@Test(.timeLimit(.minutes(1)))
func writerScheduleRoomGuardKeepsCaptureOnDiskAboveFloor() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 8_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/room.caf")

    let floor: Int64 = 64_000
    let probe = FreeBytesProbe()
    let (syncs, syncSignal) = AsyncStream<Void>.makeStream()
    var policy = FlushPolicy()
    policy.minimumFreeBytes = floor
    policy.fullSyncEvery = .zero
    policy.files.freeBytes = { [probe] url, minimum in
        probe.read(url, floor: minimum)
    }
    policy.files.sync = { _ in
        syncSignal.yield(())
        return true
    }

    let recorder = Recorder(policy: policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let problems = capture.signals.problems

    // The successful sync is an explicit signal that a drain cadence passed.
    var syncIterator = syncs.makeAsyncIterator()
    _ = await syncIterator.next()
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    var seen: [CaptureProblem] = []
    for await problem in problems { seen.append(problem) }

    let reads = probe.snapshot()
    #expect(reads.count >= 2)  // start plus a free-space check during a drain cadence
    #expect(reads.allSatisfy { $0.floor == floor })
    #expect(seen.isEmpty)
    #expect(take.summary.storage == .onDisk)
    #expect(take.clip.samples == source)
    #expect(try CAFFile.read(caf).samples == source)
}

private struct FreeBytesRead: Sendable {
    let url: URL
    let floor: Int64
}

private final class FreeBytesProbe: Sendable {
    private let reads = Mutex<[FreeBytesRead]>([])

    func read(_ url: URL, floor: Int64) -> Int64? {
        reads.withLock { $0.append(FreeBytesRead(url: url, floor: floor)) }
        return floor + 1
    }

    func snapshot() -> [FreeBytesRead] {
        reads.withLock { $0 }
    }
}
