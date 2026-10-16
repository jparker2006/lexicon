import Foundation
import Testing
import LexiconDomain
@testable import Transcription

private enum RolloverCutRace: Sendable {
    case result(CloudSession.End)
    case secondConnection
}

@Suite struct MuseRolloverCutTests {
    @Test(.timeLimit(.minutes(1))) func unexpectedCutWhileDrainingFirstRolloverSessionDoesNotReconnect() async throws {
        var preferences = Preferences.defaults
        preferences.cloudModel = .museVoice
        preferences.localModel = nil
        let keys: @Sendable (CredentialID) -> String? = { _ in "synthetic-muse-key" }
        let access = try #require(CloudAccess.granted(
            by: preferences,
            for: .app(.unknown),
            keys: keys
        ))

        var policy = CloudSession.Policy()
        policy.rolloverSamples = 1
        policy.paceAudio = false
        let clock = TestClock()
        let firstSocket = MuseSocket()
        let secondSocket = MuseSocket()
        let cloud = MuseScriptedCloud(clock: clock, policy: policy, sockets: [firstSocket, secondSocket])
        let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

        await firstSocket.wait { !$0.textMessages.isEmpty }
        session.send(PCMChunk(index: 0, samples: [43]))
        session.send(PCMChunk(index: 1, samples: [47]))
        session.audioEnded()
        firstSocket.post(MuseServerFrame.acknowledgement)
        await firstSocket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }

        firstSocket.post(MuseServerFrame.transcript("First session."))
        firstSocket.drop(NSError(domain: "synthetic.muse", code: 1011))

        let firstEvent = await withTaskGroup(of: RolloverCutRace.self) { group in
            group.addTask { .result(await session.result) }
            group.addTask {
                await cloud.wait { $0.connects > 1 }
                return .secondConnection
            }

            let event = await group.next() ?? .secondConnection
            session.close()
            group.cancelAll()
            return event
        }

        guard case .result(.failed) = firstEvent else {
            Issue.record("an unexpected cut during drain must fail the cloud leg before rollover")
            return
        }
        #expect(cloud.log.connects == 1)
        #expect(firstSocket.log.serverDropped)
        #expect(secondSocket.log.messages.isEmpty)
    }
}
