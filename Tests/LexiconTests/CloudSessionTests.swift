import Testing
import LexiconCore
import LexiconDomain
@testable import Transcription

// The cloud race (#66) at the engine's seam: one attempt at a time on a scripted
// provider and a fake clock, so each case waits on exactly the signal it is about.
// CloudRaceTests runs the same race through the whole Conductor. No keys, mic or
// network; every wait is an explicit signal, never a sleep.

private let cloudPreferences: Preferences = {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    preferences.localModelLinger = .seconds(600)
    return preferences
}()

private let fakeKeys: @Sendable (CredentialID) -> String? = { _ in "fake-key" }

private func grantedAccess(_ preferences: Preferences) throws -> CloudAccess {
    try #require(CloudAccess.granted(by: preferences, app: .unknown, keys: fakeKeys))
}

private func pcm(_ index: Int) -> PCMChunk {
    PCMChunk(index: index, samples: [1, 2, 3])
}

@Test(.timeLimit(.minutes(1))) func revokingAccessMidDictationClosesTheStreamAndLocalFinishes() async throws {
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [])
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local text."), cloud: cloud.link, clock: clock)
    let access = try grantedAccess(cloudPreferences)
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: access, terms: [Term(text: "gstack")])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    input.yield(pcm(1))
    await cloud.wait { $0.audioFrames >= 2 }
    access.revoke(.privateModeOn)
    await cloud.wait { $0.closed }
    let framesAtRevoke = cloud.log.audioFrames
    for index in 2...4 { input.yield(pcm(index)) }
    input.finish()
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(heard.text == "Local text.")
    let cloudAttempt = try #require(heard.attempts.first { $0.model == .cloud(.museVoice) })
    #expect(cloudAttempt.result == .failed)
    #expect(cloudAttempt.error?.contains("privateModeOn") == true)
    #expect(framesAtRevoke == 2)
    #expect(cloud.log.audioFrames == framesAtRevoke)  // no audio reaches the provider after the revoke
    #expect(cloud.log.finalized == false)
    #expect(clock.now.offset == .zero)
}

@Test(.timeLimit(.minutes(1))) func partialsAndFinalsReachCleanupInOrder() async throws {
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [
        .partial("ship the", afterFrames: 1),
        .final("Ship the release.", afterFrames: 2),
        .final("Today.", afterFrames: 2),
        Reply(cue: .afterFinalize(.milliseconds(50)), message: .end),
    ])
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local text."), cloud: cloud.link, clock: clock)
    // A Term shaped like a key is text leaving the Mac, so the Secret guard keeps it home.
    let keyShaped = Term(text: "sk-" + "Zq8vT2mWx9LkR4pN7bYc")
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: try grantedAccess(cloudPreferences),
                               terms: [Term(text: "gstack"), keyShaped])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)
    let segments = attempt.segments
    let collecting = Task { () -> [SpeechSegment] in
        var collected: [SpeechSegment] = []
        for await segment in segments { collected.append(segment) }
        return collected
    }

    input.yield(pcm(0))
    input.yield(pcm(1))
    await cloud.wait { $0.audioFrames >= 2 }
    input.finish()
    let steps = Task {
        await clock.waitForSleep(endingAt: .milliseconds(50))  // the provider's end, after finalize
        await clock.waitForSleep(endingAt: .milliseconds(300))  // the race deadline
        await clock.advance(by: .milliseconds(50))
    }
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))
    await steps.value
    let heardSegments = await collecting.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .cloud(.museVoice))
    #expect(heard.text == "Ship the release. Today.")
    #expect(heard.attempts.first { $0.model == .cloud(.museVoice) }?.result == .won)
    #expect(heardSegments == [
        SpeechSegment(text: "ship the", isFinal: false),
        SpeechSegment(text: "Ship the release.", isFinal: true),
        SpeechSegment(text: "Today.", isFinal: true),
    ])
    #expect(cloud.log.sessionStarts == ["gstack"])  // the Terms reach the provider at session start, minus the key
}

@Test(.timeLimit(.minutes(1))) func aSecretFinalNeverReachesCleanup() async throws {
    let secret = "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4"
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [.final("Use \(secret) for the deploy.", afterFrames: 1)])
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local text."), cloud: cloud.link, clock: clock)
    let access = try grantedAccess(cloudPreferences)
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: access, terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)
    let segments = attempt.segments
    let collecting = Task { () -> [SpeechSegment] in
        var collected: [SpeechSegment] = []
        for await segment in segments { collected.append(segment) }
        return collected
    }

    input.yield(pcm(0))
    await cloud.wait { $0.closed }  // the Secret guard cuts the session
    #expect(access.revoked == .secretFound)
    input.finish()
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))
    let heardSegments = await collecting.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(heard.text == "Local text.")
    // The guard runs before a final is yielded, so nothing reached the stream at all.
    #expect(heardSegments.isEmpty)
    let cloudAttempt = try #require(heard.attempts.first { $0.model == .cloud(.museVoice) })
    #expect(cloudAttempt.result == .failed)
}

@Test(.timeLimit(.minutes(1))) func aSessionTheProviderEndsBeforeFinalizeLosesToLocal() async throws {
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [Reply(cue: .afterFrames(1), message: .end)])
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local text."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: try grantedAccess(cloudPreferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    await cloud.wait { $0.closed }
    input.finish()
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    let cloudAttempt = try #require(heard.attempts.first { $0.model == .cloud(.museVoice) })
    #expect(cloudAttempt.result == .failed)
    #expect(clock.now.offset == .zero)
}

@Test(.timeLimit(.minutes(1))) func aProviderErrorGoesToLocal() async throws {
    // A zero delay still goes through the clock, which returns from it at once: the
    // error lands without advancing time.
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [Reply(cue: .afterFinalize(.zero), message: .error("busy"))])
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local text."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: try grantedAccess(cloudPreferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    input.finish()
    await cloud.wait { $0.closed }  // the error ends the session, which closes the socket
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    let cloudAttempt = try #require(heard.attempts.first { $0.model == .cloud(.museVoice) })
    #expect(cloudAttempt.result == .failed)
    #expect(clock.now.offset == .zero)
}

@Test(.timeLimit(.minutes(1))) func withNoLocalModelTheCloudWaitsPastTheDeadline() async throws {
    var preferences = cloudPreferences
    preferences.localModel = nil
    // The provider's end, 500 ms after finalize, completes the cloud text.
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [
        .final("Ship the gstack release today.", afterFrames: 1),
        Reply(cue: .afterFinalize(.milliseconds(500)), message: .end),
    ])
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: try grantedAccess(preferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    input.finish()
    let steps = Task {
        await clock.waitForSleep(endingAt: .milliseconds(500))  // the provider's end
        await clock.waitForSleep(endingAt: .milliseconds(300))  // the race deadline
        await clock.advance(by: .milliseconds(300))  // the deadline passes with no answer; the cloud keeps waiting
        await clock.advance(by: .milliseconds(200))
    }
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))
    await steps.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .cloud(.museVoice))
    #expect(heard.text == "Ship the gstack release today.")
    #expect(heard.attempts.map(\.model) == [.cloud(.museVoice)])
}

@Test(.timeLimit(.minutes(1))) func withNoLocalModelASilentCloudGivesUpAndTheDictationWaits() async throws {
    var preferences = cloudPreferences
    preferences.localModel = nil
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [])
    let engine = SpeechEngine(local: nil, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: preferences, access: try grantedAccess(preferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    input.finish()
    await cloud.wait { $0.finalized }
    let steps = Task {
        await clock.waitForSleep(endingAt: .seconds(10))  // the give-up time
        await clock.advance(by: .seconds(10))
    }
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))
    await steps.value
    await cloud.wait { $0.closed }  // giving up closes the socket instead of leaving it open

    guard case .unavailable(let reason) = outcome, case .providerError = reason else {
        Issue.record("expected providerError, got \(outcome)")
        return
    }
    #expect(reason.waits)
    #expect(reason.waitsForNetwork)
}

@Test(.timeLimit(.minutes(1))) func offlineKeepsTheLocalModelLoaded() async throws {
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [], networkUp: false)
    let model = HeldModel()
    let engine = SpeechEngine(local: model, cloud: cloud.link, clock: clock)
    // The engine feeds the path to residency from its own task. Pin the state the test
    // starts in, so the attempt never races that task.
    await engine.residency?.networkChanged(reachable: false)
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: try grantedAccess(cloudPreferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    input.finish()
    let outcome = await engine.begin(feed: feed, plan: plan).finish(AudioClip(samples: [1, 2, 3]))

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(await model.loads == 1)
    #expect(await model.isResident)
    #expect(await engine.residency?.unloadScheduled == false)  // offline: resident, no idle timer
    #expect(cloud.log.connects == 0)
}

@Test(.timeLimit(.minutes(1))) func losingTheNetworkWhileIdleCancelsTheUnloadTimer() async throws {
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [])
    let model = HeldModel()
    let engine = SpeechEngine(local: model, cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: try grantedAccess(cloudPreferences), terms: [])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    input.finish()
    // No answer from the cloud: the deadline hands the Dictation to local.
    let steps = Task {
        await clock.waitForSleep(endingAt: .milliseconds(300))
        await clock.advance(by: .milliseconds(300))
    }
    _ = await attempt.finish(AudioClip(samples: [1, 2, 3]))
    await steps.value

    // The idle timer is armed when the Dictation ends, after its text is back.
    while await engine.residency?.unloadScheduled != true { await Task.yield() }
    cloud.path.update(isUp: false)
    while await engine.residency?.unloadScheduled != false { await Task.yield() }
    #expect(await model.isResident)
    #expect(await model.unloads == 0)
}

@Test(.timeLimit(.minutes(1))) func aDictationWithNoCloudModelOpensNoSocket() async throws {
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: [])
    let engine = SpeechEngine(local: ScriptedTranscriber(text: "Local text."), cloud: cloud.link, clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: try grantedAccess(.defaults), terms: [Term(text: "gstack")])
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)

    input.yield(pcm(0))
    input.finish()
    let outcome = await attempt.finish(AudioClip(samples: [1, 2, 3]))

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.model == .local(.parakeetUnified))
    #expect(heard.attempts.map(\.model) == [.local(.parakeetUnified)])
    #expect(cloud.log.connects == 0)
}

/// A local model that counts its loads and unloads and hears "Local text.".
private actor HeldModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private(set) var isResident = false
    private(set) var loads = 0
    private(set) var unloads = 0

    func load() {
        loads += 1
        isResident = true
    }

    func unload() {
        unloads += 1
        isResident = false
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String { "Local text." }
}
