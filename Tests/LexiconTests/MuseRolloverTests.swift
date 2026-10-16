import Foundation
import Testing
import LexiconDomain
@testable import Transcription

private let museRolloverPreferences: Preferences = {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModel = nil
    return preferences
}()

private let museRolloverKeys: @Sendable (CredentialID) -> String? = { _ in "synthetic-muse-key" }

private enum RolloverProgress: Sendable, Equatable {
    case answerReturned
    case laterAudioReachedSecondSession
}

@Test(.timeLimit(.minutes(1))) func rolloverKeepsLaterCapturedAudioAndJoinsSessionFinals() async throws {
    let clock = TestClock()
    var policy = CloudSession.Policy()
    policy.rolloverSamples = 7
    policy.paceAudio = false

    let firstSocket = MuseSocket()
    let lastSocket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, policy: policy,
                                  sockets: [firstSocket, lastSocket], paceAudio: false)
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let access = try #require(CloudAccess.granted(by: museRolloverPreferences, for: .app(.unknown),
                                                   keys: museRolloverKeys))
    let plan = SpeechPlan.make(preferences: museRolloverPreferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()

    let chunks = [
        PCMChunk(index: 0, samples: [Int16.min, -2, 0]),
        PCMChunk(index: 1, samples: [1, 2, 3, 4, 5]),
        PCMChunk(index: 2, samples: [-9]),
        PCMChunk(index: 3, samples: [7]),
    ]
    let originalSamples = chunks.flatMap(\.samples)

    let (answerEvents, answerContinuation) = AsyncStream<SpeechOutcome>.makeStream(
        bufferingPolicy: .bufferingNewest(1))
    let answer = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        let outcome = await attempt.finish(AudioClip(samples: originalSamples))
        answerContinuation.yield(outcome)
        answerContinuation.finish()
        return outcome
    }


    input.yield(chunks[0])
    input.yield(chunks[1])
    await firstSocket.wait { !$0.textMessages.isEmpty }
    firstSocket.post(MuseServerFrame.acknowledgement)
    await firstSocket.wait { $0.endStreamSent }

    // These captured chunks remain queued while the first healthy session
    // finishes its final and the next session opens.
    input.yield(chunks[2])
    input.yield(chunks[3])
    input.finish()


    firstSocket.post(MuseServerFrame.transcript("First session.", audioProcessedMs: 0))
    firstSocket.finishNormally()

    let progress = await withTaskGroup(of: RolloverProgress.self) { group in
        group.addTask {
            var events = answerEvents.makeAsyncIterator()
            _ = await events.next()
            return .answerReturned
        }
        group.addTask {
            await lastSocket.wait { !$0.textMessages.isEmpty }
            lastSocket.post(MuseServerFrame.acknowledgement)
            await lastSocket.wait { !$0.binaryMessages.isEmpty }
            return .laterAudioReachedSecondSession
        }
        let first = await group.next() ?? .answerReturned
        group.cancelAll()
        return first
    }

    #expect(progress == .laterAudioReachedSecondSession)
    guard progress == .laterAudioReachedSecondSession else { return }

    await lastSocket.wait { $0.endStreamSent }
    lastSocket.post(MuseServerFrame.transcript("Second session.", audioProcessedMs: 0))
    lastSocket.finishNormally()

    guard case .text(let heard) = await answer.value else {
        Issue.record("expected the completed Muse answer")
        return
    }
    #expect(heard.text == "First session. Second session.")

    let sentFrames = [firstSocket, lastSocket].flatMap { $0.log.binaryMessages }
    #expect(sentFrames == chunks.map { pcm16LittleEndian($0.samples) })
    #expect(sentFrames.flatMap { Array($0) } == Array(pcm16LittleEndian(originalSamples)))
    #expect(!firstSocket.log.binaryMessages.isEmpty)
    #expect(!lastSocket.log.binaryMessages.isEmpty)
}

private func pcm16LittleEndian(_ samples: [Int16]) -> Data {
    Data(samples.flatMap { sample in
        let bits = UInt16(bitPattern: sample)
        return [UInt8(bits & 0xff), UInt8(bits >> 8)]
    })
}
