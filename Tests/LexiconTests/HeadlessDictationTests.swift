import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// The never-lose spine (#46), headless: the real Conductor on a synthesized WAV,
// a scripted engine instead of a speech model, a destination that records text.
// No mic, keys or network.

private let spoken = "Um, so can you, uh, refactor the useAuth hook so it it doesn't re-render on every keystroke?"
private let typed = "Can you refactor the useAuth hook so it doesn't re-render on every keystroke?"

@Test func aShortWavIsTypedAndSavedInHistory() async throws {
    let source = syntheticSamples(count: 19_200)  // 1.2 s
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    let engine = ScriptedTranscriber(text: spoken)
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults, local: engine)

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .inserted)
    #expect(result.versions == TextVersions(model: spoken, cleaned: typed))
    #expect(result.lag != nil)
    #expect(await engine.heard.map(\.samples) == [source])

    let row = try #require(await system.history.dictation(result.id))
    #expect(row.status == .inserted)
    #expect(row.origin == .file)
    #expect(row.versions == TextVersions(model: spoken, cleaned: typed))
    #expect(row.finalText == typed)
    #expect(row.model == .local(.parakeetUnified))
    #expect(row.cleanup == .rulesOnly(.off))
    #expect(row.lag != nil)  // stored in whole milliseconds
    #expect(row.audio == .onDisk)
    #expect(try CAFFile.read(system.history.audioURL(for: result.id)).samples == source)
}

@Test func textIsQueuedForHistoryBeforeItIsTyped() async throws {
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let destination = StatusAtInsert(history: history)
    let conductor = Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: spoken)), cleanup: Cleanup(),
        lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)

    #expect(result.status == .inserted)
    #expect(await destination.seen == [.ready])  // saved, paste in progress
}

@Test func withNoSpeechModelTheDictationWaitsAndKeepsItsAudio() async throws {
    let source = syntheticSamples(count: 8_000)
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults, local: nil)

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .waiting)
    #expect(result.versions == nil)
    let row = try #require(await system.history.dictation(result.id))
    #expect(row.status == .waiting)
    #expect(row.audio == .onDisk)
    #expect(try CAFFile.read(system.history.audioURL(for: result.id)).samples == source)
}

@Test(.timeLimit(.minutes(1)))
func onAFullDiskTheTextIsStillTypedAndJakeIsTold() async throws {
    let source = syntheticSamples(count: 19_200)
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let conductor = Conductor(
        recorder: Recorder(policy: .diskFull), speech: SpeechEngine(local: ScriptedTranscriber(text: spoken)),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: HeadlessDestination(),
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
    let events = await conductor.events()

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()

    #expect(result.status == .inserted)
    #expect(result.versions?.cleaned == typed)
    let row = try #require(await history.dictation(result.id))
    #expect(row.audio == .ramOnly)
    #expect(!FileManager.default.fileExists(atPath: history.audioURL(for: result.id).path))
    var notices: [Notice] = []
    for await event in events {
        if case .notice(let notice) = event { notices.append(notice) }
        if case .finished = event { break }
    }
    #expect(notices.contains(.diskTrouble))
}

@Test(.timeLimit(.minutes(1)))
func aMicThatFailsToStartLeavesTheNextFnPressWorking() async throws {
    let paths = AppPaths.temporary()
    let conductor = Conductor(
        recorder: Recorder(hardware: .noMic), speech: SpeechEngine(local: ScriptedTranscriber(text: spoken)),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: try HistoryStore(paths: paths),
        destination: HeadlessDestination(), preferences: PreferencesStore(fixed: .defaults),
        secrets: Secrets(.environment), keyboard: nil, fixes: nil, jev: nil)
    var events = await conductor.events().makeAsyncIterator()

    var unavailable = 0
    for _ in 1...2 {
        await conductor.handle(.dictationBegan(at: .now()))
        while let event = await events.next() {
            if case .notice(.microphoneUnavailable) = event {
                unavailable += 1
                break
            }
        }
    }
    #expect(unavailable == 2)  // the second fn press tried the mic again instead of being dropped
}

@Test(.timeLimit(.minutes(1))) func insertTargetsCannotBeMadeOutsideTheirModules() async throws {
    let imports = "import AppText\nimport KeyInput\nimport LexiconCore\nimport LexiconDomain\n"
    let fetched = try await compile(imports + """
        func live(_ app: TargetApp) async -> TargetApp.Target? { await app.target() }
        func headless(_ destination: HeadlessDestination) async -> HeadlessDestination.Target? {
            await destination.target()
        }
        """)
    #expect(fetched.status == 0, "control snippet must compile: \(fetched.output)")

    let live = try await compile(imports + """
        func make(_ clock: InputClock) -> TargetApp.Target {
            TargetApp.Target(focus: FocusSnapshot(pid: 1, fieldFingerprint: nil), bundleID: nil,
                             mark: clock.mark(), capturedAt: .now())
        }
        """)
    #expect(live.status != 0)
    #expect(live.output.contains("inaccessible"), "\(live.output)")

    let headless = try await compile(imports + """
        func make() -> HeadlessDestination.Target {
            HeadlessDestination.Target(serial: 0, focus: FocusSnapshot(pid: 1, fieldFingerprint: nil))
        }
        """)
    #expect(headless.status != 0)
    #expect(headless.output.contains("inaccessible"), "\(headless.output)")
}

@Test(.timeLimit(.minutes(1))) func finishingASpeechAttemptTwiceIsACompileError() async throws {
    let imports = "import LexiconDomain\nimport Transcription\n"
    let once = try await compile(imports + """
        func run(_ attempt: consuming SpeechAttempt, _ clip: AudioClip) async { _ = await attempt.finish(clip) }
        """)
    #expect(once.status == 0, "control snippet must compile: \(once.output)")

    let twice = try await compile(imports + """
        func run(_ attempt: consuming SpeechAttempt, _ clip: AudioClip) async {
            _ = await attempt.finish(clip)
            _ = await attempt.finish(clip)
        }
        """)
    #expect(twice.status != 0)
    #expect(twice.output.contains("consumed more than once"), "\(twice.output)")
}

/// Records the History status of each Dictation at the moment it is typed.
private actor StatusAtInsert: TextDestination {
    struct Target: Sendable {}
    let history: HistoryStore
    private(set) var seen: [DictationStatus?] = []
    init(history: HistoryStore) { self.history = history }

    func context() -> AppContext { .unknown }
    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(.unknown) } }
    func target() -> Target? { Target() }
    func insert(_ text: String, for id: DictationID, at target: Target) async -> Delivery {
        // Reads run on History's writer queue after every event recorded before them.
        seen.append(await history.dictation(id)?.status)
        return .inserted(InsertionReceipt(appBundleID: nil, fieldFingerprint: nil, caretAfter: nil,
                                          contextBefore: "", contextAfter: "", insertedAt: Date()))
    }
}

@Test func headlessKeysComeFromTheEnvironment() {
    setenv("LEXICON_KEY_CLEANUP_OPENROUTER", "test-value", 1)
    defer { unsetenv("LEXICON_KEY_CLEANUP_OPENROUTER") }
    let lookup = Secrets(.environment).lookup
    #expect(lookup(.cleanup) == "test-value")
}
