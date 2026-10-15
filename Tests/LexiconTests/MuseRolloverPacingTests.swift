import Foundation
import Testing
import LexiconDomain
@testable import Transcription

private func rolloverPacingPreferences() -> Preferences {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModel = nil
    return preferences
}

private func rolloverPacingAccess(_ preferences: Preferences) throws -> CloudAccess {
    let keys: @Sendable (CredentialID) -> String? = { _ in "synthetic-muse-pacing-key" }
    return try #require(CloudAccess.granted(by: preferences, for: .app(.unknown), keys: keys))
}

private func rolloverPacingPCM(_ samples: [Int16]) -> Data {
    Data(samples.flatMap { sample in
        let bits = UInt16(bitPattern: sample)
        return [UInt8(bits & 0xff), UInt8(bits >> 8)]
    })
}

private enum PacingObservation: Sendable, Equatable {
    case deadline
    case audioSent
}

/// The losing wait is cancelled once the first observable event wins. Both
/// sides are driven by test signals, so the old immediate-send path cannot hang.
private func firstPacingObservation(clock: TestClock, socket: MuseSocket,
                                    endingAt offset: Duration) async -> PacingObservation {
    await withTaskGroup(of: PacingObservation.self) { group in
        group.addTask {
            await clock.waitForSleep(endingAt: offset)
            return .deadline
        }
        group.addTask {
            await socket.wait { !$0.binaryMessages.isEmpty }
            return .audioSent
        }
        let first = await group.next() ?? .deadline
        group.cancelAll()
        return first
    }
}

@Test(.timeLimit(.minutes(1))) func queuedMuseChunkPacingDeadlineCarriesAcrossRollover() async throws {
    let clock = TestClock()
    var policy = CloudSession.Policy()
    policy.rolloverSamples = 160
    policy.paceAudio = true

    let firstSocket = MuseSocket()
    let secondSocket = MuseSocket()
    let thirdSocket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, policy: policy,
                                  sockets: [firstSocket, secondSocket, thirdSocket], paceAudio: true)
    let preferences = rolloverPacingPreferences()
    let access = try rolloverPacingAccess(preferences)
    let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

    let chunks = [
        PCMChunk(index: 0, samples: Array(repeating: Int16(101), count: 160)), // 10 ms.
        PCMChunk(index: 1, samples: Array(repeating: Int16(-103), count: 320)), // 20 ms.
        PCMChunk(index: 2, samples: Array(repeating: Int16(107), count: 80)), // 5 ms.
    ]
    for chunk in chunks { session.send(chunk) }
    session.audioEnded()

    await cloud.wait { $0.connects == 1 }
    await firstSocket.wait { $0.textMessages.count == 1 }
    firstSocket.post(MuseServerFrame.acknowledgement)
    await firstSocket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
    firstSocket.post(MuseServerFrame.transcript("First."))
    firstSocket.finishNormally()

    await cloud.wait { $0.connects == 2 }
    await secondSocket.wait { $0.textMessages.count == 1 }
    secondSocket.post(MuseServerFrame.acknowledgement)

    let secondPacing = await firstPacingObservation(clock: clock, socket: secondSocket,
                                                    endingAt: .milliseconds(10))
    #expect(secondPacing == .deadline)
    guard secondPacing == .deadline else {
        session.close()
        await session.waitUntilClosed()
        #expect(secondSocket.log.clientCloseCalls == 1)
        #expect(clock.sleepers == 0)
        return
    }
    #expect(secondSocket.log.binaryMessages.isEmpty)
    await clock.advance(by: .milliseconds(10))
    await secondSocket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
    #expect(clock.now.offset == .milliseconds(10))

    secondSocket.post(MuseServerFrame.transcript("Second."))
    secondSocket.finishNormally()
    await cloud.wait { $0.connects == 3 }
    await thirdSocket.wait { $0.textMessages.count == 1 }
    thirdSocket.post(MuseServerFrame.acknowledgement)

    let thirdPacing = await firstPacingObservation(clock: clock, socket: thirdSocket,
                                                   endingAt: .milliseconds(30))
    #expect(thirdPacing == .deadline)
    guard thirdPacing == .deadline else {
        session.close()
        await session.waitUntilClosed()
        #expect(thirdSocket.log.clientCloseCalls == 1)
        #expect(clock.sleepers == 0)
        return
    }
    #expect(thirdSocket.log.binaryMessages.isEmpty)
    await clock.advance(by: .milliseconds(20))
    await thirdSocket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
    #expect(clock.now.offset == .milliseconds(30))

    let sent = [firstSocket, secondSocket, thirdSocket].flatMap { $0.log.binaryMessages }
    #expect(sent == chunks.map { rolloverPacingPCM($0.samples) })

    thirdSocket.post(MuseServerFrame.transcript("Third."))
    thirdSocket.finishNormally()
    let result = await session.result
    guard case .text(let heard) = result else {
        Issue.record("expected completed rollover transcript, got \(result)")
        await session.waitUntilClosed()
        return
    }
    #expect(heard == "First. Second. Third.")
    await session.waitUntilClosed()
    #expect(clock.sleepers == 0)
}
