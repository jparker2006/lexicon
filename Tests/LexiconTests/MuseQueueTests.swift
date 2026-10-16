import Synchronization
import Testing
import LexiconDomain
@testable import Transcription

@Suite struct MuseQueueTests {
    private let maxBufferedBytes = 12
    private let chunkSamples: [Int16] = [101, -202, 303]

    @Test(.timeLimit(.minutes(1))) func stalledConnectBoundsQueueAndRejectsLaterAudio() async throws {
        let clock = TestClock()
        let connect = MuseBarrier()
        let socket = MuseSocket()
        let cloud = configuredCloud(clock: clock, socket: socket, connectBarrier: connect)
        let session = try makeSession(cloud)

        await connect.waitUntilEntered()
        #expect(cloud.log.connects == 1)
        await fillThenOverflow(session, alreadyBufferedBytes: 0)

        #expect(connect.enteredCount == 1)
        #expect(socket.log.clientCloseCalls == 0) // connect was cancelled before a socket existed
    }

    @Test(.timeLimit(.minutes(1))) func stalledAcknowledgementBoundsQueueAndRejectsLaterAudio() async throws {
        let clock = TestClock()
        let socket = MuseSocket()
        let cloud = configuredCloud(clock: clock, socket: socket)
        let session = try makeSession(cloud)

        await socket.wait { $0.textMessages.count == 1 && $0.pendingReceives > 0 }
        #expect(socket.log.binaryMessages.isEmpty)
        await fillThenOverflow(session, alreadyBufferedBytes: 0)

        #expect(socket.log.binaryMessages.isEmpty) // no PCM was sent before acknowledgment
        #expect(socket.log.clientCloseCalls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func stalledAudioSendCountsInflightBytesAgainstQueueBound() async throws {
        let clock = TestClock()
        let audioSend = MuseBarrier()
        let socket = MuseSocket(audioSendBarrier: audioSend)
        let cloud = configuredCloud(clock: clock, socket: socket)
        let session = try makeSession(cloud)

        await socket.wait { $0.textMessages.count == 1 && $0.pendingReceives > 0 }
        socket.post(MuseServerFrame.acknowledgement)
        session.send(PCMChunk(index: 0, samples: chunkSamples))
        await audioSend.waitUntilEntered()
        #expect(session.bufferedBytes == chunkSamples.count * MemoryLayout<Int16>.size)
        #expect(socket.log.binaryMessages.isEmpty) // send is still held at the socket boundary
        await fillThenOverflow(session, alreadyBufferedBytes: chunkSamples.count * MemoryLayout<Int16>.size)

        #expect(audioSend.enteredCount == 1)
        #expect(socket.log.clientCloseCalls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func overflowKeepsCompleteCaptureForTheLocalWinner() async throws {
        let clock = TestClock()
        let connect = MuseBarrier()
        let socket = MuseSocket()
        let cloud = configuredCloud(clock: clock, socket: socket, connectBarrier: connect)
        let localCapture = LocalAudioAudit()
        let engine = SpeechEngine(local: CapturingTranscriber(audit: localCapture), cloud: cloud.link, clock: clock)
        let access = try grantedAccess()
        let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
        let (feed, input) = AudioFeed.makeStream()
        let attempt = await engine.begin(feed: feed, plan: plan)
        let original = (0..<30).map { Int16($0 * 37 - 500) }
        let chunks = stride(from: 0, to: original.count, by: 3).enumerated().map { index, start in
            PCMChunk(index: index, samples: Array(original[start..<start + 3]))
        }

        await connect.waitUntilEntered()
        for chunk in chunks { input.yield(chunk) }
        input.finish()
        await localCapture.waitForAppended(original.count)

        let outcome = await attempt.finish(AudioClip(samples: original))
        guard case .text(let heard) = outcome else {
            Issue.record("expected the local transcription, got \(outcome)")
            return
        }

        #expect(heard.model == .local(.parakeetUnified))
        #expect(heard.text == "Local transcript.")
        #expect(heard.attempts.first { $0.model == .cloud(.museVoice) }?.result == .failed)
        #expect(localCapture.appendedSamples == original)
        #expect(localCapture.finishedSamples == original)
        #expect(localCapture.finishCalls == 1)
        #expect(cloud.log.connects == 1)
        #expect(connect.enteredCount == 1)
        #expect(socket.log.clientCloseCalls == 0)
    }

    private func fillThenOverflow(_ session: CloudSession, alreadyBufferedBytes: Int) async {
        let chunkBytes = chunkSamples.count * MemoryLayout<Int16>.size
        #expect(alreadyBufferedBytes == 0 || alreadyBufferedBytes == chunkBytes)
        #expect(session.bufferedBytes == alreadyBufferedBytes)
        #expect(alreadyBufferedBytes <= maxBufferedBytes)

        var nextIndex = 0
        var currentBytes = alreadyBufferedBytes
        while currentBytes < maxBufferedBytes {
            session.send(PCMChunk(index: nextIndex, samples: chunkSamples))
            nextIndex += 1
            currentBytes = session.bufferedBytes
            #expect(currentBytes <= maxBufferedBytes)
        }
        #expect(currentBytes == maxBufferedBytes)

        session.send(PCMChunk(index: nextIndex, samples: chunkSamples))
        #expect(session.bufferedBytes <= maxBufferedBytes)
        await session.waitUntilClosed()
        #expect(session.bufferedBytes == 0)

        let end = await session.result
        guard case .failed = end else {
            Issue.record("overflow should fail and close the cloud session")
            return
        }

        // Once overflow closes the cloud leg, later captured chunks are discarded at the boundary.
        for index in (nextIndex + 1)..<(nextIndex + 9) {
            session.send(PCMChunk(index: index, samples: chunkSamples))
            #expect(session.bufferedBytes == 0)
        }
    }

    private func configuredCloud(clock: TestClock, socket: MuseSocket,
                                connectBarrier: MuseBarrier? = nil) -> MuseScriptedCloud {
        var policy = CloudSession.Policy()
        policy.maxBufferedBytes = maxBufferedBytes
        policy.paceAudio = false
        return MuseScriptedCloud(clock: clock, policy: policy, sockets: [socket],
                                 connectBarrier: connectBarrier, paceAudio: false)
    }

    private func makeSession(_ cloud: MuseScriptedCloud) throws -> CloudSession {
        CloudSession(model: .museVoice, access: try grantedAccess(), terms: [], link: cloud.link)
    }

    private func grantedAccess() throws -> CloudAccess {
        try #require(CloudAccess.granted(by: preferences, for: .app(.unknown), keys: fakeKeys))
    }

    private var preferences: Preferences {
        var value = Preferences.defaults
        value.cloudModel = .museVoice
        value.localModelLinger = .seconds(600)
        return value
    }

    private var fakeKeys: @Sendable (CredentialID) -> String? { { _ in "synthetic-queue-key" } }
}

private final class LocalAudioAudit: Sendable {
    private struct State {
        var appendedSamples: [Int16] = []
        var finishedSamples: [Int16]?
        var finishCalls = 0
    }

    private let state = Mutex(State())
    private let changes: AsyncStream<Int>
    private let publish: AsyncStream<Int>.Continuation

    init() {
        (changes, publish) = AsyncStream<Int>.makeStream()
    }

    var appendedSamples: [Int16] { state.withLock { $0.appendedSamples } }
    var finishedSamples: [Int16]? { state.withLock { $0.finishedSamples } }
    var finishCalls: Int { state.withLock { $0.finishCalls } }

    func append(_ samples: [Int16]) {
        let count = state.withLock { state -> Int in
            state.appendedSamples.append(contentsOf: samples)
            return state.appendedSamples.count
        }
        publish.yield(count)
    }

    func finish(_ clip: AudioClip) {
        state.withLock { state in
            state.finishCalls += 1
            state.finishedSamples = clip.samples
        }
        publish.finish()
    }

    func waitForAppended(_ count: Int) async {
        if appendedSamples.count >= count { return }
        for await seen in changes where seen >= count { return }
    }
}

private struct CapturingTranscriber: LocalTranscriber {
    let audit: LocalAudioAudit

    var model: LocalModel { .parakeetUnified }
    var isResident: Bool { get async { true } }
    func load() async throws {}
    func unload() async {}
    func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        CapturingLocalSession(audit: audit)
    }
}

private struct CapturingLocalSession: LocalSession {
    let audit: LocalAudioAudit

    func append(_ samples: [Int16]) { audit.append(samples) }
    func finish(_ clip: AudioClip) async throws -> String {
        audit.finish(clip)
        return "Local transcript."
    }
    func cancel() {}
}
