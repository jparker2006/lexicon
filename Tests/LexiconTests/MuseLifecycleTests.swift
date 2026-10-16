import Foundation
import Testing
import LexiconCore
import LexiconDomain
@testable import Transcription

private func musePreferences(local: Bool) -> Preferences {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModel = local ? .parakeetUnified : nil
    return preferences
}

private func museAccess(for preferences: Preferences) throws -> CloudAccess {
    let keys: @Sendable (CredentialID) -> String? = { _ in "synthetic-muse-key" }
    return try #require(CloudAccess.granted(by: preferences, for: .app(.unknown), keys: keys))
}

private func readyForTranscript(_ socket: MuseSocket, audioFrames: Int = 1) async {
    await socket.wait { $0.textMessages.count == 1 }
    socket.post(MuseServerFrame.acknowledgement)
    await socket.wait { $0.binaryMessages.count == audioFrames && $0.endStreamSent }
}

@Test(.timeLimit(.minutes(1))) func completedTranscriptReturnsBeforeNormalCloseAndSocketDrains() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: false)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let samples: [Int16] = [101, -20, 7]
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: samples))
    }

    input.yield(PCMChunk(index: 0, samples: samples))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await readyForTranscript(socket)
    socket.post(MuseServerFrame.transcript("Muse answer."))

    let outcome = await result.value
    guard case .text(let heard) = outcome else {
        Issue.record("expected a completed Muse answer, got \(outcome)")
        return
    }
    #expect(heard.model == .cloud(.museVoice))
    #expect(heard.text == "Muse answer.")
    #expect(socket.log.serverFinishedNormally == false)
    #expect(socket.log.clientCloseCalls == 0)

    await socket.wait { $0.pendingReceives > 0 }
    socket.finishNormally()
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }
    #expect(socket.log.serverFinishedNormally)
}

@Test(.timeLimit(.minutes(1))) func missingNormalCloseExpiresFiveSecondsAfterCompletedAnswer() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: false)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: [17, 19]))
    }

    input.yield(PCMChunk(index: 0, samples: [17, 19]))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await readyForTranscript(socket)
    socket.post(MuseServerFrame.transcript("Answer before cleanup."))

    let outcome = await result.value
    guard case .text(let heard) = outcome else {
        Issue.record("expected a completed Muse answer, got \(outcome)")
        return
    }
    await socket.wait { $0.pendingReceives > 0 }
    #expect(socket.log.clientCloseCalls == 0)
    await clock.waitForSleep(endingAt: .seconds(5))
    await clock.advance(by: .seconds(5))
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }

    #expect(heard.model == .cloud(.museVoice))
    #expect(heard.text == "Answer before cleanup.")
    #expect(clock.now.offset == .seconds(5))
}

@Test(.timeLimit(.minutes(1))) func cancellingAttemptClosesMuseSocketAndPendingReceive() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: false)
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: try museAccess(for: preferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(PCMChunk(index: 0, samples: [3, 5]))
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.pendingReceives > 0 }
    attempt.cancel()
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }
    input.finish()

    #expect(socket.log.binaryMessages.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func revokingAccessClosesMuseSocketBeforeAnyAudioSend() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: true)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local answer."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(PCMChunk(index: 0, samples: [3, 5]))
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 }
    access.revoke(.privateModeOn)
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }
    input.finish()
    let outcome = await attempt.finish(AudioClip(samples: [3, 5]))

    guard case .text(let heard) = outcome else {
        Issue.record("expected local text after revoke, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(socket.log.binaryMessages.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func losingCloudResultClosesTheOwnedMuseSocket() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: true)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local wins."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: [11, 13]))
    }

    input.yield(PCMChunk(index: 0, samples: [11, 13]))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.pendingReceives > 0 }
    await clock.waitForSleep(endingAt: .milliseconds(300))
    await clock.advance(by: .milliseconds(300))
    let outcome = await result.value
    await socket.wait { $0.clientCloseCalls == 1 && $0.pendingReceives == 0 }

    guard case .text(let heard) = outcome else {
        Issue.record("expected local text after the cloud deadline, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(heard.text == "Local wins.")
    #expect(cloud.log.connects == 1)
}

@Test(.timeLimit(.minutes(1))) func unexpected1011DropUsesLocalWithoutReconnectOrReplay() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: true)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local after drop."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let samples: [Int16] = [23, -29, 31]
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: samples))
    }

    input.yield(PCMChunk(index: 0, samples: samples))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await readyForTranscript(socket)
    socket.drop(NSError(domain: "synthetic.muse", code: 1011))
    let outcome = await result.value
    await socket.wait { $0.clientCloseCalls == 1 }

    guard case .text(let heard) = outcome else {
        Issue.record("expected local text after a transport drop, got \(outcome)")
        return
    }
    let cloudAttempt = try #require(heard.attempts.first { $0.model == .cloud(.museVoice) })
    #expect(heard.model == .local(.parakeetUnified))
    #expect(cloudAttempt.result == .failed)
    #expect(cloud.log.connects == 1)
    #expect(socket.log.binaryMessages.count == 1)
}

@Test(.timeLimit(.minutes(1))) func ambiguous1011AudioSendIsNotReplayed() async throws {
    let clock = TestClock()
    let socket = MuseSocket(failOnBinary: 1, failure: NSError(domain: "synthetic.muse", code: 1011))
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: true)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local after send error."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: [37, -41]))
    }

    input.yield(PCMChunk(index: 0, samples: [37, -41]))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await socket.wait { $0.textMessages.count == 1 }
    socket.post(MuseServerFrame.acknowledgement)
    await socket.wait { $0.binaryMessages.count == 1 && $0.clientCloseCalls == 1 }
    let outcome = await result.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected local text after an ambiguous send, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(cloud.log.connects == 1)
    #expect(socket.log.binaryMessages.count == 1)
}

@Test(.timeLimit(.minutes(1))) func providerErrorTextIsSanitizedBeforeLocalFallback() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: true)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local after provider error."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: [43]))
    }

    input.yield(PCMChunk(index: 0, samples: [43]))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await readyForTranscript(socket)
    socket.post(MuseServerFrame.error("synthetic echoed secret"))
    let outcome = await result.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected local text after a provider error, got \(outcome)")
        return
    }
    let cloudAttempt = try #require(heard.attempts.first { $0.model == .cloud(.museVoice) })
    #expect(heard.model == .local(.parakeetUnified))
    #expect(cloudAttempt.error == "provider error")
    #expect(cloudAttempt.error?.contains("synthetic echoed secret") == false)
}

@Test(.timeLimit(.minutes(1))) func blankCompletedMuseTranscriptFallsBackToLocalText() async throws {
    let clock = TestClock()
    let socket = MuseSocket()
    let cloud = MuseScriptedCloud(clock: clock, sockets: [socket])
    let preferences = musePreferences(local: true)
    let access = try museAccess(for: preferences)
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local heard the words."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let result = Task {
        let attempt = await engine.begin(feed: feed, plan: plan)
        return await attempt.finish(AudioClip(samples: [47, 53]))
    }

    input.yield(PCMChunk(index: 0, samples: [47, 53]))
    input.finish()
    await cloud.wait { $0.connects == 1 }
    await readyForTranscript(socket)
    socket.post(MuseServerFrame.transcript(" \n "))
    let outcome = await result.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected local text after a blank Muse result, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(heard.text == "Local heard the words.")
    await socket.wait { $0.clientCloseCalls == 1 }
}
