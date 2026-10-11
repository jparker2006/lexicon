import Foundation
import Synchronization
import Testing
@testable import AudioCapture
@testable import LexiconCore
import Cleanup
import History
import LexiconDomain
@testable import Transcription
import WordStore

// Private mode and always-private apps (#68), headless: the real Conductor on a
// WAV, a scripted fake provider and a fake network path. The scripted link's
// connect is the only way a socket could open, so `connects == 0` means nothing
// left the Mac.

private let cloudHeard = "Ship the gstack release today."
private let localHeard = "Ship the G stack release today."
private let bank = AppContext(bundleID: "com.example.bank", appName: nil, windowTitle: nil, workingDirectory: nil)
private let editor = AppContext(bundleID: "com.example.editor", appName: nil, windowTitle: nil, workingDirectory: nil)

/// The fake provider's key, from the environment like `lexicon-eval`'s.
private let fakeKey: Secrets = {
    setenv(Secrets.environmentName(for: .speech(.museVoice)), "fake-speech-key", 1)
    return Secrets(.environment)
}()

private struct Pipeline {
    let conductor: Conductor<HeadlessDestination>
    let destination: HeadlessDestination
    let history: HistoryStore
    let cloud: ScriptedCloud
    let clock = TestClock()
    let preferences: PreferencesStore

    /// `local: false`: no local model, so a Dictation with no cloud text waits.
    init(_ script: [Reply] = Reply.finalText(cloudHeard, after: .milliseconds(100)), app: AppContext = editor,
         alwaysPrivate: Set<String> = [], local: Bool = true, networkUp: Bool = true) throws {
        var settings = Preferences.defaults
        settings.cloudModel = .museVoice
        settings.alwaysPrivateApps = alwaysPrivate
        preferences = PreferencesStore(fixed: settings)
        cloud = ScriptedCloud(clock: clock, script: script, networkUp: networkUp)
        destination = HeadlessDestination(context: app)
        let paths = AppPaths.temporary()
        history = try HistoryStore(paths: paths)
        conductor = Conductor(
            recorder: Recorder(),
            speech: SpeechEngine(local: local ? ScriptedTranscriber(text: localHeard) : nil, cloud: cloud.link,
                                 clock: clock),
            cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
            preferences: preferences, secrets: fakeKey, keyboard: nil, fixes: nil, jev: nil)
    }

    func dictate() throws -> Task<DictationResult, Never> {
        let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
        return Task { await conductor.dictate(file: wav, pace: .asFastAsPossible) }
    }

    /// The Dictation's result, or nil once the test's time limit cancels the wait. The
    /// Dictation's own task is not cancelled with the test, so without this a broken
    /// revoke would hang the whole run instead of failing this test.
    func result(of running: Task<DictationResult, Never>) async -> DictationResult? {
        final class Waiting: Sendable {
            let state = Mutex<(wake: CheckedContinuation<DictationResult?, Never>?, cancelled: Bool)>((nil, false))
        }
        let waiting = Waiting()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { wake in
                let cancelled = waiting.state.withLock { state in
                    if !state.cancelled { state.wake = wake }
                    return state.cancelled
                }
                if cancelled { return wake.resume(returning: nil) }
                Task {
                    let result = await running.value
                    waiting.state.withLock { $0.wake.take() }?.resume(returning: result)
                }
            }
        } onCancel: {
            waiting.state.withLock { state in
                state.cancelled = true
                return state.wake.take()
            }?.resume(returning: nil)
        }
    }

    /// Lets the scripted cloud answer at 100 ms and the 300 ms deadline pass, for a
    /// Dictation whose stream is open.
    func answer() async {
        await clock.waitForSleep(endingAt: .milliseconds(100))
        await clock.waitForSleep(endingAt: .milliseconds(300))
        await clock.advance(by: .milliseconds(100))
    }
}

@Test(.timeLimit(.minutes(1))) func anAlwaysPrivateAppGetsNoCloudCallsAndAnotherAppDoes() async throws {
    let pipeline = try Pipeline(app: bank, alwaysPrivate: [bank.bundleID!])

    let inBank = try #require(await pipeline.result(of: pipeline.dictate()))
    #expect(inBank.model == .local(.parakeetUnified))
    #expect(inBank.attempts.map(\.model) == [.local(.parakeetUnified)])
    #expect(pipeline.cloud.log.connects == 0)

    await pipeline.destination.moveFocus(to: editor)
    let running = try pipeline.dictate()
    await pipeline.answer()
    #expect(await pipeline.result(of: running)?.model == .cloud(.museVoice))
    #expect(pipeline.cloud.log.connects == 1)
}

@Test(.timeLimit(.minutes(1))) func focusMovingIntoAnAlwaysPrivateAppCutsTheStreamAndLocalFinishes() async throws {
    let pipeline = try Pipeline(app: editor, alwaysPrivate: [bank.bundleID!])
    let running = try pipeline.dictate()

    await pipeline.cloud.wait { $0.connects == 1 }
    await pipeline.destination.moveFocus(to: bank)
    await pipeline.cloud.wait { $0.closed }
    try #require(pipeline.cloud.log.closed)
    let result = try #require(await pipeline.result(of: running))

    #expect(result.model == .local(.parakeetUnified))
    #expect(result.attempts.first { $0.model == .cloud(.museVoice) }?.result == .failed)
    #expect(pipeline.clock.now.offset == .zero)  // local was used at once, not after the deadline
}

@Test(.timeLimit(.minutes(1))) func anAppLexiconCannotNameGetsNoCloudOnceTheListHasAnApp() async throws {
    let pipeline = try Pipeline(app: .unknown, alwaysPrivate: [bank.bundleID!])

    let result = try #require(await pipeline.result(of: pipeline.dictate()))

    #expect(result.model == .local(.parakeetUnified))
    #expect(pipeline.cloud.log.connects == 0)
}

@Test(.timeLimit(.minutes(1))) func addingTheFrontAppToTheListMidDictationCutsTheStream() async throws {
    let pipeline = try Pipeline(app: editor, alwaysPrivate: [bank.bundleID!])
    let running = try pipeline.dictate()

    await pipeline.cloud.wait { $0.connects == 1 }
    pipeline.preferences.update { $0.alwaysPrivateApps.insert(editor.bundleID!) }
    await pipeline.cloud.wait { $0.closed }
    try #require(pipeline.cloud.log.closed)
    #expect(await pipeline.result(of: running)?.model == .local(.parakeetUnified))
}

/// The waiting retry is watched like a live run, and a revocation is carried
/// forward: once Private mode cut a try, later tries never reopen the cloud,
/// even after Private mode is turned off again.
@Test(.timeLimit(.minutes(1))) func aRetryCutByPrivateModeNeverReopensTheCloud() async throws {
    let pipeline = try Pipeline([], local: false, networkUp: false)

    // Offline at fn-down with no local model: the Dictation waits for the network.
    let first = try #require(await pipeline.result(of: pipeline.dictate()))
    #expect(first.status == .waiting)
    #expect(pipeline.cloud.log.connects == 0)

    // The network returns: the retry streams the clip to the cloud.
    await pipeline.clock.waitForSleep(endingAt: SpeechEngine.retryInterval)
    pipeline.cloud.path.update(isUp: true)
    await pipeline.cloud.wait { $0.connects == 1 }

    // Private mode turned on mid-try cuts that stream at once.
    pipeline.preferences.update { $0.privacy = .private }
    await pipeline.cloud.wait { $0.closed }
    try #require(pipeline.cloud.log.closed)

    // Turned off again before the next try: the Dictation stays local for good.
    await pipeline.clock.waitForSleep(endingAt: SpeechEngine.retryInterval)
    pipeline.preferences.update { $0.privacy = .standard }
    await pipeline.clock.advance(by: SpeechEngine.retryInterval)
    await pipeline.clock.waitForSleep(endingAt: SpeechEngine.retryInterval * 2)  // that try found no engine

    #expect(pipeline.cloud.log.connects == 1)
    #expect(await pipeline.history.owesText(first.id))
}

@Test(.timeLimit(.minutes(1))) func aRetryInPrivateModeOpensNoSocket() async throws {
    let pipeline = try Pipeline([], local: false, networkUp: false)

    let first = try #require(await pipeline.result(of: pipeline.dictate()))
    #expect(first.status == .waiting)

    // Private mode turned on while the Dictation waits; then the network returns.
    await pipeline.clock.waitForSleep(endingAt: SpeechEngine.retryInterval)
    pipeline.preferences.update { $0.privacy = .private }
    pipeline.cloud.path.update(isUp: true)
    // The try ran with no engine and went back to waiting, on the retry timer.
    await pipeline.clock.waitForSleep(endingAt: SpeechEngine.retryInterval)
    await pipeline.clock.advance(by: SpeechEngine.retryInterval)
    await pipeline.clock.waitForSleep(endingAt: SpeechEngine.retryInterval * 2)

    #expect(pipeline.cloud.log.connects == 0)
}

/// Wifi off: every Dictation in a scripted run gets local text, with no socket
/// opened and nothing queued for the network's return.
@Test(.timeLimit(.minutes(1))) func withTheNetworkDownEveryDictationGetsLocalText() async throws {
    let pipeline = try Pipeline(networkUp: false)

    for _ in 0..<10 {
        let result = try #require(await pipeline.result(of: pipeline.dictate()))
        #expect(result.status == .inserted)
        #expect(result.model == .local(.parakeetUnified))
        #expect(result.versions?.cleaned.isEmpty == false)
    }
    #expect(pipeline.cloud.log.connects == 0)

    // The network returns: only a new Dictation streams; none of the ten is sent.
    pipeline.cloud.path.update(isUp: true)
    let running = try pipeline.dictate()
    await pipeline.answer()
    #expect(await pipeline.result(of: running)?.model == .cloud(.museVoice))
    #expect(pipeline.cloud.log.connects == 1)
}
