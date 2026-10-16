import Testing
import LexiconDomain
@testable import Transcription

@Suite struct MuseMalformedAckTests {
    @Test(.timeLimit(.minutes(1))) func nonStringTypeDoesNotReleaseQueuedPCM() async throws {
        #expect(MuseVoice().parse(.text(#"{"type":7,"sessionId":"s"}"#)) == .ignore)
        let clock = TestClock()
        let socket = MuseSocket()
        var preferences = Preferences.defaults
        preferences.cloudModel = .museVoice
        preferences.localModelLinger = .seconds(600)
        let keys: @Sendable (CredentialID) -> String? = { _ in "synthetic-key" }
        let access = try #require(CloudAccess.granted(
            by: preferences,
            for: .app(.unknown),
            keys: keys
        ))
        var policy = CloudSession.Policy()
        policy.paceAudio = false
        let cloud = MuseScriptedCloud(clock: clock, policy: policy, sockets: [socket])
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

        await socket.wait { $0.textMessages.count == 1 && $0.pendingReceives > 0 }
        session.send(PCMChunk(index: 0, samples: [101, -202, 303]))
        socket.post(.text(#"{"type":7,"sessionId":"s"}"#))
        socket.post(MuseServerFrame.transcript("premature"))
        await session.waitUntilClosed()

        #expect(socket.log.binaryMessages.isEmpty)
    }
}
