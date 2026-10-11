import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import Cleanup
import History
import LexiconDomain
@testable import Transcription
import WordStore

// The cloud race (#66), headless: the real Conductor on a WAV, a scripted fake
// provider instead of a socket, a scripted local model, and a fake clock for the
// 300 ms deadline. Each case checks what History says won.

private let cloudHeard = "Ship the gstack release today."
private let localHeard = "Ship the G stack release today."

private let withCloud: Preferences = {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    return preferences
}()

/// The fake provider's key, from the environment like `lexicon-eval`'s. Set once and
/// never unset; a test that needs no key reads a Keychain service that holds nothing.
private let fakeKey: Secrets = {
    setenv(Secrets.environmentName(for: .speech(.museVoice)), "fake-speech-key", 1)
    return Secrets(.environment)
}()

private struct Race {
    let conductor: Conductor<HeadlessDestination>
    let history: HistoryStore
    let cloud: ScriptedCloud
    let clock: TestClock
    let preferences = PreferencesStore(fixed: withCloud)

    init(_ script: [Reply], connectError: (any Error)? = nil, networkUp: Bool = true,
         secrets: Secrets = fakeKey) throws {
        clock = TestClock()
        cloud = ScriptedCloud(clock: clock, script: script, connectError: connectError, networkUp: networkUp)
        let paths = AppPaths.temporary()
        history = try HistoryStore(paths: paths)
        conductor = Conductor(
            recorder: Recorder(),
            speech: SpeechEngine(local: ScriptedTranscriber(text: localHeard), cloud: cloud.link, clock: clock),
            cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history,
            destination: HeadlessDestination(), preferences: preferences, secrets: secrets,
            keyboard: nil, fixes: nil, jev: nil)
    }

    /// Dictates a short WAV and returns the running Dictation.
    func dictate() throws -> Task<DictationResult, Never> {
        let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
        return Task { await conductor.dictate(file: wav, pace: .asFastAsPossible) }
    }

    /// The model History stored for the Dictation, and every engine's attempt.
    func landed(_ running: Task<DictationResult, Never>) async throws
        -> (model: SpeechModel?, attempts: [SpeechModel: AttemptRecord.Result]) {
        let result = await running.value
        await history.flush()
        let row = try #require(await history.dictation(result.id))
        #expect(row.status == .inserted)
        #expect(row.model == result.model)
        return (row.model, Dictionary(uniqueKeysWithValues: result.attempts.map { ($0.model, $0.result) }))
    }
}

@Test(.timeLimit(.minutes(1))) func aCloudFinalAt200MillisecondsWins() async throws {
    let race = try Race(Reply.finalText(cloudHeard, after: .milliseconds(200)))
    let running = try race.dictate()

    await race.clock.waitForSleep(endingAt: .milliseconds(200))  // the provider's answer
    await race.clock.waitForSleep(endingAt: .milliseconds(300))  // the race deadline
    await race.clock.advance(by: .milliseconds(200))

    let (model, attempts) = try await race.landed(running)
    #expect(model == .cloud(.museVoice))
    #expect(attempts[.cloud(.museVoice)] == .won)
    #expect(await running.value.versions?.model == cloudHeard)
    #expect(race.cloud.log.keys == ["fake-speech-key"])
    #expect(race.cloud.log.audioFrames > 0)
    #expect(race.cloud.log.finalized)
}

@Test(.timeLimit(.minutes(1))) func aCloudFinalAt400MillisecondsLosesToLocal() async throws {
    let race = try Race(Reply.finalText(cloudHeard, after: .milliseconds(400)))
    let running = try race.dictate()

    await race.clock.waitForSleep(endingAt: .milliseconds(400))
    await race.clock.waitForSleep(endingAt: .milliseconds(300))
    await race.clock.advance(by: .milliseconds(300))

    let (model, attempts) = try await race.landed(running)
    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.local(.parakeetUnified)] == .won)
    #expect(attempts[.cloud(.museVoice)] == .timedOut)
    #expect(await running.value.versions?.model == localHeard)
    await race.cloud.wait { $0.closed }  // the losing stream is closed, not left open
}

// The next cases never move the clock: they finish only because local is used at once.

@Test(.timeLimit(.minutes(1))) func aSocketErrorGoesToLocalWithNoWait() async throws {
    let race = try Race([Reply(cue: .afterFinalize(.zero), message: .drop)])

    let (model, attempts) = try await race.landed(try race.dictate())

    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.cloud(.museVoice)] == .failed)
    #expect(race.cloud.log.connects == 1)  // no second connection: local is already racing
    #expect(race.clock.now.offset == .zero)
}

@Test(.timeLimit(.minutes(1))) func aSocketThatNeverOpensGoesToLocalWithNoWait() async throws {
    let race = try Race([], connectError: URLError(.cannotConnectToHost))

    let (model, attempts) = try await race.landed(try race.dictate())

    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.cloud(.museVoice)] == .failed)
}

@Test(.timeLimit(.minutes(1))) func aMissingKeyGoesToLocalWithNoWaitAndNoConnection() async throws {
    let noKeys = Secrets(.keychain(service: "com.example.lexicon-tests.holds-no-keys"))
    let race = try Race(Reply.finalText(cloudHeard, after: .milliseconds(100)), secrets: noKeys)

    let (model, attempts) = try await race.landed(try race.dictate())

    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.cloud(.museVoice)] == .failed)
    #expect(race.cloud.log.connects == 0)
}

@Test(.timeLimit(.minutes(1))) func offlineGoesToLocalWithNoConnection() async throws {
    let race = try Race(Reply.finalText(cloudHeard, after: .milliseconds(100)), networkUp: false)

    let (model, attempts) = try await race.landed(try race.dictate())

    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.cloud(.museVoice)] == .failed)
    #expect(race.cloud.log.connects == 0)
}

@Test(.timeLimit(.minutes(1))) func aSecretInAFinalizedSegmentCutsTheStreamAndLocalFinishes() async throws {
    let secret = "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4"
    let race = try Race([.final("the token is \(secret)", afterFrames: 1)]
                        + Reply.finalText(cloudHeard, after: .milliseconds(100)))
    let running = try race.dictate()

    await race.cloud.wait { $0.closed }
    let (model, attempts) = try await race.landed(running)

    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.cloud(.museVoice)] == .failed)
    #expect(race.clock.now.offset == .zero)
}

@Test(.timeLimit(.minutes(1))) func privateModeTurnedOnMidDictationCutsTheStreamAndLocalFinishes() async throws {
    let race = try Race(Reply.finalText(cloudHeard, after: .milliseconds(200)))
    let running = try race.dictate()

    await race.cloud.wait { $0.connects == 1 }
    race.preferences.update { $0.privacy = .private }
    await race.cloud.wait { $0.closed }
    let (model, attempts) = try await race.landed(running)

    #expect(model == .local(.parakeetUnified))
    #expect(attempts[.cloud(.museVoice)] == .failed)
    #expect(race.clock.now.offset == .zero)  // local was used at once, not after the deadline
}

@Test(.timeLimit(.minutes(1))) func privateModeAtFnDownOpensNoSocketEvenWithACloudModel() async throws {
    _ = fakeKey
    var privateMode = withCloud
    privateMode.privacy = .private
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: Reply.finalText(cloudHeard, after: .milliseconds(100)))
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: privateMode,
                                         local: ScriptedTranscriber(text: localHeard), cloud: cloud.link, clock: clock)

    let result = await system.conductor.dictate(file: try writeWAV(syntheticSamples(count: 8_000), rate: 16_000,
                                                                     in: try scratchDirectory()),
                                                pace: .asFastAsPossible)

    #expect(result.model == .local(.parakeetUnified))
    #expect(result.attempts.map(\.model) == [.local(.parakeetUnified)])
    #expect(cloud.log.connects == 0)
}

/// `lexicon-eval` builds its system with `HeadlessSystem.make`: the race runs through the link it is given.
@Test(.timeLimit(.minutes(1))) func theHeadlessSystemRacesThroughTheLinkItIsGiven() async throws {
    _ = fakeKey  // the environment key HeadlessSystem's Secrets read
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: Reply.finalText(cloudHeard, after: .milliseconds(100)))
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: withCloud,
                                         local: ScriptedTranscriber(text: localHeard), cloud: cloud.link, clock: clock)
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let running = Task { await system.conductor.dictate(file: wav, pace: .asFastAsPossible) }

    await clock.waitForSleep(endingAt: .milliseconds(100))
    await clock.advance(by: .milliseconds(100))
    let result = await running.value
    await system.history.flush()

    #expect(result.model == .cloud(.museVoice))
    #expect(await system.history.dictation(result.id)?.model == .cloud(.museVoice))
}
