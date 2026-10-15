import Foundation
import Testing
import LexiconDomain
@testable import Transcription

private func lifecycleMorePreferences(local: Bool) -> Preferences {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModel = local ? .parakeetUnified : nil
    return preferences
}

private func lifecycleMoreAccess(_ preferences: Preferences) throws -> CloudAccess {
    let keys: @Sendable (CredentialID) -> String? = { _ in "synthetic-lifecycle-key" }
    return try #require(CloudAccess.granted(by: preferences, for: .app(.unknown), keys: keys))
}

private func lifecycleMorePCM(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        var littleEndian = sample.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

@Test(.timeLimit(.minutes(1))) func cloudSessionPublishesCompletedAnswerBeforeCloseAndExitsAfterGrace() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = lifecycleMorePreferences(local: false)
    let access = try lifecycleMoreAccess(preferences)
    let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)

    session.send(PCMChunk(index: 0, samples: [59, -61, 67]))
    session.audioEnded()
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 }
    socket.post(MuseServerFrame.acknowledgement)
    await socket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
    socket.post(MuseServerFrame.transcript("Published before close."))

    let firstResult = await session.result
    guard case .text(let firstText) = firstResult else {
        Issue.record("expected completed cloud text, got \(firstResult)")
        return
    }
    #expect(firstText == "Published before close.")
    await socket.wait { $0.pendingReceives > 0 }
    #expect(socket.log.clientCloseCalls == 0)
    await clock.waitForSleep(endingAt: .seconds(5))
    await clock.advance(by: .seconds(5))
    await session.waitUntilClosed()

    let repeatedResult = await session.result
    guard case .text(let repeatedText) = repeatedResult else {
        Issue.record("expected the published result to remain available, got \(repeatedResult)")
        return
    }
    #expect(repeatedText == "Published before close.")
    #expect(socket.log.clientCloseCalls == 1)
    #expect(socket.log.pendingReceives == 0)
    #expect(clock.sleepers == 0)
}

@Test(.timeLimit(.minutes(1))) func noLocalGiveUpAfterRegisteredTimerClosesStalledMuseAcknowledgment() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = lifecycleMorePreferences(local: false)
    let access = try lifecycleMoreAccess(preferences)
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let samples: [Int16] = [71, -73]
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: samples))
    }

    input.yield(PCMChunk(index: 0, samples: samples))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 && $0.pendingReceives > 0 }
    await clock.waitForSleep(endingAt: plan.race.giveUp)
    await clock.advance(by: plan.race.giveUp)
    let outcome = await result.value
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }

    guard case .unavailable(.providerError) = outcome else {
        Issue.record("expected the no-local give-up result, got \(outcome)")
        return
    }
    #expect(cloud.log.connects == 1)
    #expect(socket.log.binaryMessages.isEmpty)
    #expect(clock.sleepers == 0)
}

@Test(.timeLimit(.minutes(1))) func cumulativeMusePartialsDoNotBecomeTheReturnedAnswer() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = lifecycleMorePreferences(local: false)
    let access = try lifecycleMoreAccess(preferences)
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        let stream = attempt.segments
        let collected = Task { () -> [SpeechSegment] in
            var segments: [SpeechSegment] = []
            for await segment in stream { segments.append(segment) }
            return segments
        }
        let outcome = await attempt.finish(AudioClip(samples: [79, 83]))
        return (outcome, await collected.value)
    }

    input.yield(PCMChunk(index: 0, samples: [79, 83]))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 }
    socket.post(MuseServerFrame.acknowledgement)
    await socket.wait { $0.binaryMessages.count == 1 && $0.endStreamSent }
    socket.post(MuseServerFrame.transcript("Ship the", final: false))
    socket.post(MuseServerFrame.transcript("Ship the revised", final: false))
    socket.post(MuseServerFrame.transcript("Ship the final version."))

    let (outcome, segments) = await result.value
    guard case .text(let heard) = outcome else {
        Issue.record("expected the terminal Muse transcript, got \(outcome)")
        return
    }
    #expect(heard.model == .cloud(.museVoice))
    #expect(heard.text == "Ship the final version.")
    #expect(segments == [
        SpeechSegment(text: "Ship the", isFinal: false),
        SpeechSegment(text: "Ship the revised", isFinal: false),
        SpeechSegment(text: "Ship the final version.", isFinal: true),
    ])
    await socket.wait { $0.pendingReceives > 0 }
    socket.finishNormally()
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }
}

@Test(.timeLimit(.minutes(1))) func pacedMuseAudioWaitsEightyMillisecondsAndPreservesVariableChunks() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket], paceAudio: true)
    let preferences = lifecycleMorePreferences(local: false)
    let access = try lifecycleMoreAccess(preferences)
    let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)
    let firstSamples = Array(repeating: Int16(89), count: 1_280)  // 80 ms at 16 kHz.
    let secondSamples = Array(repeating: Int16(-97), count: 640) // 40 ms at 16 kHz.
    session.send(PCMChunk(index: 0, samples: firstSamples))
    session.send(PCMChunk(index: 1, samples: secondSamples))
    session.audioEnded()

    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 }
    socket.post(MuseServerFrame.acknowledgement)
    await socket.wait { $0.binaryMessages.count == 1 }
    await clock.waitForSleep(endingAt: .milliseconds(80))
    #expect(socket.log.binaryMessages.count == 1)
    await clock.advance(by: .milliseconds(80))
    await socket.wait { $0.binaryMessages.count == 2 && $0.endStreamSent }
    #expect(socket.log.binaryMessages == [lifecycleMorePCM(firstSamples), lifecycleMorePCM(secondSamples)])

    socket.post(MuseServerFrame.transcript("Paced final."))
    let result = await session.result
    guard case .text(let heard) = result else {
        Issue.record("expected completed paced transcript, got \(result)")
        return
    }
    #expect(heard == "Paced final.")
    await socket.wait { $0.pendingReceives > 0 }
    socket.finishNormally()
    await session.waitUntilClosed()
    #expect(clock.sleepers == 0)
}

@Test(.timeLimit(.minutes(1))) func lateMuseChunkDoesNotWaitAnotherChunkDuration() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket], paceAudio: true)
    let preferences = lifecycleMorePreferences(local: false)
    let access = try lifecycleMoreAccess(preferences)
    let session = CloudSession(model: .museVoice, access: access, terms: [], link: cloud.link)
    let samples = Array(repeating: Int16(1), count: 160) // 10 ms at 16 kHz.

    session.send(PCMChunk(index: 0, samples: samples))
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 }
    socket.post(MuseServerFrame.acknowledgement)
    await socket.wait { $0.binaryMessages.count == 1 }

    // Model the next real-time chunk arriving after the first chunk's duration.
    await clock.advance(by: .milliseconds(10))
    session.send(PCMChunk(index: 1, samples: samples))
    session.audioEnded()

    let delayed = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await clock.waitForSleep(endingAt: .milliseconds(20))
            return true
        }
        group.addTask {
            await socket.wait { $0.binaryMessages.count == 2 }
            return false
        }
        let event = await group.next() ?? true
        group.cancelAll()
        return event
    }
    #expect(!delayed)

    // Let the buggy version finish so the test can clean up after recording failure.
    if delayed { await clock.advance(by: .milliseconds(10)) }
    await socket.wait { $0.binaryMessages.count == 2 && $0.endStreamSent }
    socket.post(MuseServerFrame.transcript("Paced final."))
    let result = await session.result
    guard case .text(let heard) = result else {
        Issue.record("expected completed cloud text, got \(result)")
        return
    }
    #expect(heard == "Paced final.")
    await socket.wait { $0.pendingReceives > 0 }
    socket.finishNormally()
    await session.waitUntilClosed()
}
