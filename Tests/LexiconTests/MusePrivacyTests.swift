import Foundation
import Synchronization
import Testing
import LexiconDomain
@testable import Transcription

private func musePrivacyPreferences() -> Preferences {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModel = nil
    return preferences
}

private func musePrivacyAccess(
    keys: @escaping @Sendable (CredentialID) -> String? = { _ in "synthetic-muse-key" }
) throws -> CloudAccess {
    try #require(CloudAccess.granted(by: musePrivacyPreferences(), for: .app(.unknown), keys: keys))
}

private final class MusePrivacyAccessHolder: Sendable {
    private let state = Mutex<CloudAccess?>(nil)

    var access: CloudAccess? { state.withLock { $0 } }
    func store(_ access: CloudAccess) { state.withLock { $0 = access } }
}

private final class MusePrivacyCounter: Sendable {
    private let state = Mutex(0)

    var value: Int { state.withLock { $0 } }
    func increment() { state.withLock { $0 += 1 } }
}

private struct RevokeDuringRequestProvider: StreamingProvider {
    let access: CloudAccess
    let requestCalls: MusePrivacyCounter
    let muse = MuseVoice()

    var requiresAcknowledgment: Bool { muse.requiresAcknowledgment }

    func connectRequest(key: String) -> URLRequest {
        requestCalls.increment()
        let request = muse.connectRequest(key: key)
        access.revoke(.secretFound)
        return request
    }

    func sessionStart(key: String, terms: [Term]) -> ProviderMessage? {
        muse.sessionStart(key: key, terms: terms)
    }

    func audio(_ chunk: PCMChunk) -> ProviderMessage { muse.audio(chunk) }
    func finalize() -> ProviderMessage { muse.finalize() }
    func parse(_ message: ProviderMessage) -> ProviderEvent { muse.parse(message) }
}

@Suite struct MusePrivacyTests {
    @Test(.timeLimit(.minutes(1))) func revocationInsideKeyLookupPreventsAnyConnection() async throws {
        let holder = MusePrivacyAccessHolder()
        let keys: @Sendable (CredentialID) -> String? = { _ in
            holder.access?.revoke(.secretFound)
            return "synthetic-muse-key"
        }
        let access = try #require(CloudAccess.granted(by: musePrivacyPreferences(), for: .app(.unknown), keys: keys))
        holder.store(access)
        let cloud = MuseScriptedCloud(clock: TestClock(), sockets: [])
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

        await session.waitUntilClosed()

        #expect(access.revoked == .secretFound)
        #expect(cloud.log.connects == 0)
    }

    @Test(.timeLimit(.minutes(1))) func revocationDuringRequestPreparationPreventsConnection() async throws {
        let access = try musePrivacyAccess()
        let requestCalls = MusePrivacyCounter()
        let connectCalls = MusePrivacyCounter()
        let socket = MuseSocket()
        let provider = RevokeDuringRequestProvider(access: access, requestCalls: requestCalls)
        let clock = TestClock()
        let link = CloudLink(
            adapter: { _ in provider },
            connect: { _ in
                connectCalls.increment()
                return socket
            },
            path: NetworkPath(isUp: true),
            clock: clock
        )
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: link)

        await session.waitUntilClosed()

        #expect(requestCalls.value == 1)
        #expect(access.revoked == .secretFound)
        #expect(connectCalls.value == 0)
        #expect(socket.log.messages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func revocationBeforeConnectReturnsPreventsAuthorizationFrames() async throws {
        let access = try musePrivacyAccess()
        let connectCalls = MusePrivacyCounter()
        let socket = MuseSocket()
        let clock = TestClock()
        let link = CloudLink(
            adapter: { _ in MuseVoice() },
            connect: { _ in
                connectCalls.increment()
                access.revoke(.privateModeOn)
                return socket
            },
            path: NetworkPath(isUp: true),
            clock: clock
        )
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: link)

        await session.waitUntilClosed()

        #expect(connectCalls.value == 1)
        #expect(access.revoked == .privateModeOn)
        #expect(socket.log.messages.isEmpty)
        #expect(socket.log.clientCloseCalls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func revocationAfterAudioSuppressesLaterAudioAndEndStream() async throws {
        let clock = TestClock()
        let socket = MuseSocket()
        let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
        let access = try musePrivacyAccess()
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

        await socket.wait { !$0.textMessages.isEmpty }
        socket.post(MuseServerFrame.acknowledgement)
        session.send(PCMChunk(index: 0, samples: [11, 13]))
        await socket.wait { $0.binaryMessages.count == 1 }

        access.revoke(.privateModeOn)
        session.send(PCMChunk(index: 1, samples: [17, 19]))
        session.audioEnded()
        await session.waitUntilClosed()

        #expect(socket.log.binaryMessages.count == 1)
        #expect(socket.log.endStreamSent == false)
        #expect(socket.log.clientCloseCalls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func revocationDuringDrainDoesNotReplaceCompletedAnswer() async throws {
        let clock = TestClock()
        let socket = MuseSocket()
        let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
        let access = try musePrivacyAccess()
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

        await socket.wait { !$0.textMessages.isEmpty }
        socket.post(MuseServerFrame.acknowledgement)
        session.send(PCMChunk(index: 0, samples: [23, 29]))
        session.audioEnded()
        await socket.wait { $0.endStreamSent }
        socket.post(MuseServerFrame.transcript("Completed before drain."))

        guard case .text(let completed) = await session.result else {
            Issue.record("expected the completed Muse answer")
            return
        }
        await socket.wait { $0.pendingReceives > 0 }
        access.revoke(.privateModeOn)
        await session.waitUntilClosed()

        guard case .text(let afterRevoke) = await session.result else {
            Issue.record("drain revocation replaced the completed answer")
            return
        }
        #expect(completed == "Completed before drain.")
        #expect(afterRevoke == completed)
        #expect(socket.log.clientCloseCalls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func splitSecretAcrossRolloverFinalsIsWithheldBeforeConsumerAndStopsLaterSessions() async throws {
        let firstHalf = "Use sk-"
        let secondHalf = "x9Kq2mVb7RtL4wZp"
        #expect(!SecretGuard.matches(firstHalf))
        #expect(!SecretGuard.matches(secondHalf))
        #expect(SecretGuard.matches(firstHalf + secondHalf))

        let clock = TestClock()
        var policy = CloudSession.Policy()
        policy.rolloverSamples = 1
        policy.paceAudio = false
        let firstSocket = MuseSocket()
        let secondSocket = MuseSocket()
        let laterSocket = MuseSocket()
        let cloud = MuseScriptedCloud(clock: clock, policy: policy,
                                      sockets: [firstSocket, secondSocket, laterSocket])
        let access = try musePrivacyAccess()
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)
        let collecting = Task { () -> [SpeechSegment] in
            var segments: [SpeechSegment] = []
            for await segment in session.segments { segments.append(segment) }
            return segments
        }

        await firstSocket.wait { !$0.textMessages.isEmpty }
        session.send(PCMChunk(index: 0, samples: [31]))
        session.send(PCMChunk(index: 1, samples: [37]))
        session.send(PCMChunk(index: 2, samples: [41]))
        session.audioEnded()
        firstSocket.post(MuseServerFrame.acknowledgement)
        await firstSocket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
        firstSocket.post(MuseServerFrame.transcript(firstHalf))
        firstSocket.finishNormally()

        await secondSocket.wait { !$0.textMessages.isEmpty }
        secondSocket.post(MuseServerFrame.acknowledgement)
        await secondSocket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
        secondSocket.post(MuseServerFrame.transcript(secondHalf))
        await session.waitUntilClosed()
        let segments = await collecting.value

        #expect(access.revoked == .secretFound)
        #expect(segments == [SpeechSegment(text: firstHalf, isFinal: true)])
        #expect(cloud.log.connects == 2)
        #expect(laterSocket.log.messages.isEmpty)
        #expect(secondSocket.log.clientCloseCalls == 1)
    }
}
