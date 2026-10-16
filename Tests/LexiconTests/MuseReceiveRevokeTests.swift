import Dispatch
import Synchronization
import Testing
import LexiconDomain
@testable import Transcription

private final class CloseGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let firstClose = Mutex(false)
    private let entered: AsyncStream<Void>
    private let announce: AsyncStream<Void>.Continuation

    init() { (entered, announce) = AsyncStream<Void>.makeStream() }

    func holdFirstClose() {
        let shouldHold = firstClose.withLock { held -> Bool in
            guard !held else { return false }
            held = true
            return true
        }
        guard shouldHold else { return }
        announce.yield(())
        semaphore.wait()  // timing-ok: the test itself releases this close barrier
    }

    func waitUntilEntered() async {
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { semaphore.signal() }
}

private final class GatedCloseSocket: CloudSocket, Sendable {
    let base: MuseSocket
    let gate: CloseGate
    private let firstClose = Mutex(false)

    init(base: MuseSocket, gate: CloseGate) {
        self.base = base
        self.gate = gate
    }

    func send(_ message: ProviderMessage) async throws { try await base.send(message) }
    func receive() async throws -> ProviderMessage? { try await base.receive() }

    func close() {
        let first = firstClose.withLock { closed -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        if first { gate.holdFirstClose() }
        base.close()
    }
}

@Test(.timeLimit(.minutes(1))) func revocationDuringPendingReceiveSuppressesFinal() async throws {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModel = nil
    let keys: @Sendable (CredentialID) -> String? = { _ in "synthetic-key" }
    let access = try #require(CloudAccess.granted(
        by: preferences, for: .app(.unknown), keys: keys
    ))
    let base = MuseSocket()
    let gate = CloseGate()
    let socket = GatedCloseSocket(base: base, gate: gate)
    let link = CloudLink(
        adapter: { _ in MuseVoice() }, connect: { _ in socket },
        path: NetworkPath(isUp: true)
    )
    let session = CloudSession(model: .museVoice, access: access, terms: [], link: link)
    let collected = Task { () -> [SpeechSegment] in
        var segments: [SpeechSegment] = []
        for await segment in session.segments { segments.append(segment) }
        return segments
    }

    await base.wait { !$0.textMessages.isEmpty }
    base.post(MuseServerFrame.acknowledgement)
    session.audioEnded()
    await base.wait { $0.endStreamSent && $0.pendingReceives > 0 }

    access.revoke(.privateModeOn)
    await gate.waitUntilEntered()
    base.post(MuseServerFrame.transcript("late final"))
    let segments = await collected.value
    gate.release()
    await session.waitUntilClosed()

    #expect(segments.isEmpty)
}
