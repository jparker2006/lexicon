import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
@testable import History
import AppText
import Cleanup
import LexiconDomain
import Transcription
import WordStore

// Never lose a Dictation (#59), headless: the real Conductor on a synthesized
// WAV in a child process that SIGKILLs itself mid-Dictation, then a relaunch on
// the same data folder. Only processes these tests start are ever killed.

let crashHeard = "the crash test passes now"
private let cleaned = "the crash test passes now"  // nothing for rules-only Cleanup to change

// MARK: Launch recovery

@Test(.timeLimit(.minutes(1))) func aDictationKilledMidRecordingIsRecoveredWithItsTextAndNeverTyped() async throws {
    let root = try scratchDirectory().path
    let wav = try writeWAV(longSamples(), rate: 16_000, in: try scratchDirectory()).path
    let exit = await #expect(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
        [root = root as String, wav = wav as String] in
        let conductor = try childConductor(root: root, destination: ReportingDestination())
        let events = await conductor.events()
        Task {
            for await event in events {
                guard case .listening(let id) = event else { continue }
                report("listening \(id)")
                // Well into the recording: the writer has drained a few times.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(700)) { kill(getpid(), SIGKILL) }
            }
        }
        _ = await conductor.dictate(file: URL(filePath: wav), pace: .realtime)
        Issue.record("the Dictation finished before the kill")
    }
    let child = try #require(exit)
    let lines = ChildLines(child.standardOutputContent)
    let id = try #require(lines.ids("listening").first)
    #expect(lines.ids("typed").isEmpty)

    let relaunch = try HeadlessSystem.make(paths: AppPaths(root: URL(filePath: root)), context: .unknown,
                                           preferences: .defaults, local: ScriptedTranscriber(text: crashHeard))
    let events = await relaunch.conductor.events()
    await relaunch.conductor.recover()
    await relaunch.conductor.settle()
    await relaunch.history.flush()

    let row = try #require(await relaunch.history.dictation(id))
    #expect(row.status == .recovered)
    #expect(row.origin == .recovered)
    #expect(row.finalText == cleaned)
    #expect(await relaunch.conductor.destination.delivered.isEmpty)  // nothing typed
    let audio = try CAFFile.read(relaunch.history.audioURL(for: id)).samples
    #expect(CAFFile.state(of: relaunch.history.audioURL(for: id)) == .closed)
    #expect(audio.count >= 16_000 * 7 / 10 - 1_600)  // about 0.7 s heard, at most a drain behind
    #expect(audio == Array(longSamples().prefix(audio.count)))
    #expect(await notices(in: events, until: id).contains(.recovered(id)))
}

@Test(.timeLimit(.minutes(1))) func aCrashMidPasteNeverRetypesOnRelaunch() async throws {
    let root = try scratchDirectory().path
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory()).path
    let exit = await #expect(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
        [root = root as String, wav = wav as String] in
        let conductor = try childConductor(root: root, destination: ReportingDestination(killMidPaste: true))
        _ = await conductor.dictate(file: URL(filePath: wav), pace: .asFastAsPossible)
        Issue.record("the paste finished before the kill")
    }
    let child = try #require(exit)
    let id = try #require(ChildLines(child.standardOutputContent).ids("typed").first)

    let relaunch = try HeadlessSystem.make(paths: AppPaths(root: URL(filePath: root)), context: .unknown,
                                           preferences: .defaults, local: ScriptedTranscriber(text: crashHeard))
    await relaunch.conductor.recover()
    await relaunch.conductor.settle()
    await relaunch.history.flush()

    let row = try #require(await relaunch.history.dictation(id))
    #expect(row.status == .notInserted)
    #expect(try await reason(relaunch.history, id) == NotInsertedReason.interrupted.rawValue)
    #expect(row.finalText == cleaned)  // paste-last still has it
    #expect(row.status.canMove(to: .inserted))
    #expect(await relaunch.conductor.destination.delivered.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func recoveryLeavesADictationThisRunIsRecordingAlone() async throws {
    // fn can come before launch recovery runs: its open file and its row are this run's, not a crash's.
    let source = syntheticSamples(count: 16_000)  // 1 s
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: ScriptedTranscriber(text: crashHeard))
    let events = await system.conductor.events()
    let dictation = Task { await system.conductor.dictate(file: wav, pace: .realtime) }
    var listening: DictationID?
    for await event in events {
        if case .listening(let id) = event { listening = id; break }
    }
    let id = try #require(listening)
    // Its header is written with the first drain, up to 100 ms after first audio.
    while CAFFile.state(of: system.history.audioURL(for: id)) != .open { try await Task.sleep(for: .milliseconds(5)) }
    await system.history.flush()

    #expect(await system.history.recover().isEmpty)
    await system.conductor.recover()
    let result = await dictation.value

    #expect(result.id == id)
    #expect(result.status == .inserted)
    let row = try #require(await system.history.dictation(id))
    #expect(row.origin == .file)
    #expect(row.status == .inserted)
    #expect(try CAFFile.read(system.history.audioURL(for: id)).samples == source)
}

/// The acceptance run: 200 Dictations back to back at the speed of speech, each
/// child relaunching on the last one's data folder and SIGKILLed at a random
/// moment (launch, recovery, recording, transcribing, mid-paste). Four lanes of
/// 50 run side by side. Then one last relaunch recovers, and every Dictation
/// must have its text, its audio bit-exact, and have been typed at most once.
@Test(.timeLimit(.minutes(5)), arguments: 0..<4)
func twoHundredDictationsWithRandomKillsLoseNone(lane: Int) async throws {
    let root = try scratchDirectory().path
    let clip = syntheticSamples(count: 6_400)  // 0.4 s
    let wav = try writeWAV(clip, rate: 16_000, in: try scratchDirectory()).path
    var started: [DictationID: UInt64] = [:]
    var typed: [DictationID: Int] = [:]
    var shortfalls: [Duration] = []
    var kills = 0
    var unfinished: [(DictationID, UInt64, UInt64)] = []  // started, killed: the audio it should have kept

    while started.count < 50 {
        let killAfter = Double.random(in: 0...1.5)
        let exit = await #expect(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
            [root = root as String, wav = wav as String, killAfter = killAfter as Double] in
            DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) {
                report("killed \(HostTime.now().nanoseconds)")
                kill(getpid(), SIGKILL)
            }
            let conductor = try childConductor(root: root, destination: ReportingDestination())
            let events = await conductor.events()
            Task {
                for await event in events {
                    if case .started(let id) = event { report("started \(id) \(HostTime.now().nanoseconds)") }
                }
            }
            await conductor.recover()
            while true { _ = await conductor.dictate(file: URL(filePath: wav), pace: .realtime) }
        }
        let child = try #require(exit)
        kills += 1
        let lines = ChildLines(child.standardOutputContent)
        for (id, at) in lines.started { started[id] = at }
        for id in lines.ids("typed") { typed[id, default: 0] += 1 }
        if let killed = lines.killed, let last = lines.started.last { unfinished.append((last.0, last.1, killed)) }
    }

    let relaunch = try HeadlessSystem.make(paths: AppPaths(root: URL(filePath: root)), context: .unknown,
                                           preferences: .defaults, local: ScriptedTranscriber(text: crashHeard))
    await relaunch.conductor.recover()
    await relaunch.conductor.settle()
    await relaunch.history.flush()
    #expect(await relaunch.conductor.destination.delivered.isEmpty)

    let rows = try await relaunch.history.read { db in
        try db.query("SELECT \(DictationRecord.columns) FROM dictation").compactMap(DictationRecord.init(row:))
    }
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    for id in started.keys { #expect(byID[id] != nil, "Dictation \(id) has no row") }
    for row in rows {
        let samples = (try? CAFFile.read(relaunch.history.audioURL(for: row.id)))?.samples ?? []
        #expect(samples == Array(clip.prefix(samples.count)), "audio of \(row.id) is not what was said")
        if row.status == .failed {
            // Killed between creating the file and writing its first audio: nothing was said yet.
            #expect(samples.isEmpty, "Dictation \(row.id) failed with audio")
            continue
        }
        #expect([.inserted, .notInserted, .recovered].contains(row.status), "Dictation \(row.id) is \(row.status)")
        #expect(row.finalText == cleaned, "Dictation \(row.id) has no text")
        #expect(typed[row.id, default: 0] <= 1, "Dictation \(row.id) was typed \(typed[row.id, default: 0]) times")
        if row.status == .inserted { #expect(typed[row.id] == 1) }
    }
    for (id, began, killed) in unfinished {
        guard byID[id] != nil, let samples = try? CAFFile.read(relaunch.history.audioURL(for: id)).samples
        else { continue }
        let said = min(Duration.nanoseconds(Int64(killed) - Int64(began)), .milliseconds(400))
        shortfalls.append(said - .milliseconds(samples.count * 1_000 / PCM16k.sampleRate))
    }
    let worst = shortfalls.max() ?? .zero
    let statuses = Dictionary(grouping: rows, by: \.status).map { "\($0.value.count) \($0.key)" }.sorted()
    print("lane \(lane): \(started.count) Dictations, \(kills) kills, \(statuses.joined(separator: ", ")), worst audio lost \(worst)")
    // The writer drains every 100 ms, so a crash loses at most about that; the
    // margin is for a loaded machine's scheduling, not for lost audio.
    #expect(worst <= .milliseconds(250))
}

// MARK: The waiting path

@Test(.timeLimit(.minutes(1))) func withNoModelInstalledADictationWaitsThenGetsTextOnceItIs() async throws {
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let clock = TestClock()
    let model = InstallableModel()
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: model, clock: clock)
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    #expect(result.status == .waiting)
    #expect(await finished(in: events, result.id) == .waiting)

    // Tried again with still no model: it keeps waiting, quietly.
    await clock.waitForSleepers(2)  // the retry, and the model's idle unload
    await clock.advance(by: SpeechEngine.retryInterval)
    await clock.waitForSleepers(2)
    await system.history.flush()
    #expect(await system.history.dictation(result.id)?.status == .waiting)

    await model.install()
    await clock.advance(by: SpeechEngine.retryInterval)
    #expect(await finished(in: events, result.id) == .inserted)  // nothing touched since: the late text is typed
    await system.history.flush()
    let row = try #require(await system.history.dictation(result.id))
    #expect(row.status == .inserted)
    #expect(row.finalText == cleaned)
    #expect(await system.conductor.destination.delivered[result.id] == cleaned)
}

@Test(.timeLimit(.minutes(1))) func aDictationStillWaitingAtRelaunchIsRecoveredOnceAModelIsInstalled() async throws {
    let paths = AppPaths.temporary()
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let first = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                        local: InstallableModel(), clock: TestClock())
    let id = await first.conductor.dictate(file: wav, pace: .asFastAsPossible).id
    await first.history.flush()

    // Relaunch, model still missing: recovery tries it, and it goes on waiting.
    let clock = TestClock()
    let model = InstallableModel()
    let relaunch = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                           local: model, clock: clock)
    let events = await relaunch.conductor.events()
    await relaunch.conductor.recover()
    #expect(await finished(in: events, id) == .waiting)
    await relaunch.history.flush()
    #expect(await relaunch.history.dictation(id)?.status == .waiting)
    #expect(await relaunch.history.dictation(id)?.origin == .recovered)

    await model.install()
    await clock.waitForSleepers(2)
    await clock.advance(by: SpeechEngine.retryInterval)
    #expect(await finished(in: events, id) == .recovered)
    await relaunch.history.flush()
    let row = try #require(await relaunch.history.dictation(id))
    #expect(row.status == .recovered)
    #expect(row.finalText == cleaned)
    #expect(await relaunch.conductor.destination.delivered.isEmpty)  // recovered text is never typed
}

@Test(.timeLimit(.minutes(1))) func aDeletedWaitingDictationStopsTrying() async throws {
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let clock = TestClock()
    let model = InstallableModel()
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: model, clock: clock)
    let id = await system.conductor.dictate(file: wav, pace: .asFastAsPossible).id
    system.history.record(.deleted(id))
    await system.history.flush()

    await model.install()
    await clock.waitForSleepers(2)
    await clock.advance(by: SpeechEngine.retryInterval)
    await system.conductor.settle()
    #expect(await model.transcribed == 0)
    #expect(await system.conductor.destination.delivered.isEmpty)
}

// MARK: Helpers

/// What a relaunch builds: the real Conductor on `root`, a fake engine that hears `heard`.
func childConductor(root: String, destination: ReportingDestination) throws -> Conductor<ReportingDestination> {
    let paths = AppPaths(root: URL(filePath: root))
    let history = try HistoryStore(paths: paths)
    destination.history = history
    return Conductor(recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: crashHeard)),
                     cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history,
                     destination: destination, preferences: PreferencesStore(fixed: .defaults),
                     secrets: Secrets(.environment), keyboard: nil, fixes: nil, jev: nil)
}

extension Conductor {
    /// Returns once every recovery and live run has landed, and no waiting
    /// Dictation is mid-retry (one asleep until its next try does not count).
    func settle() async {
        while let task = inFlight.values.first { _ = await task.value }
    }
}

/// Types nothing: says on stdout which Dictation it would have typed, before
/// reporting it typed. `killMidPaste`: dies right there, with the text saved
/// as ready (the crash this guards against).
final class ReportingDestination: TextDestination, @unchecked Sendable {
    struct Target: Sendable {}
    let killMidPaste: Bool
    /// Set once, before the Conductor runs.
    var history: HistoryStore?

    init(killMidPaste: Bool = false) { self.killMidPaste = killMidPaste }

    func context() async -> AppContext { .unknown }
    func target() async -> Target? { Target() }
    func insert(_ text: String, for id: DictationID, at target: Target) async -> Delivery {
        if killMidPaste {
            await history?.flush()  // `.textReady` is on disk: the row says ready
            report("typed \(id)")
            kill(getpid(), SIGKILL)
        }
        report("typed \(id)")
        return .inserted(InsertionReceipt(appBundleID: nil, fieldFingerprint: nil, caretAfter: nil,
                                          contextBefore: "", contextAfter: "", insertedAt: Date()))
    }
}

/// A local model that is not installed until `install`.
private actor InstallableModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var installed = false
    private(set) var isResident = false
    private(set) var transcribed = 0

    func install() { installed = true }
    func load() throws {
        guard installed else { throw LocalModelNotInstalled(model) }
        isResident = true
    }
    func unload() { isResident = false }
    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) throws -> String {
        guard installed else { throw LocalModelNotInstalled(model) }
        transcribed += 1
        return crashHeard
    }
}

/// A child's stdout, one fact per line.
private struct ChildLines {
    let lines: [[Substring]]
    init(_ output: [UInt8]) {
        lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map { $0.split(separator: " ") }
    }
    func ids(_ word: String) -> [DictationID] {
        lines.filter { $0.first == Substring(word) }.compactMap { $0.dropFirst().first.flatMap { UUID(uuidString: String($0)) } }
            .map(DictationID.init(uuid:))
    }
    var started: [(DictationID, UInt64)] {
        lines.compactMap { line in
            guard line.count == 3, line[0] == "started", let uuid = UUID(uuidString: String(line[1])),
                  let at = UInt64(line[2]) else { return nil }
            return (DictationID(uuid: uuid), at)
        }
    }
    var killed: UInt64? { lines.last { $0.first == "killed" }.flatMap { $0.dropFirst().first }.flatMap { UInt64($0) } }
}

private func reason(_ history: HistoryStore, _ id: DictationID) async throws -> String? {
    try await history.read { db in
        try db.query("SELECT status_reason FROM dictation WHERE id = ?", [.text(id.description)]).first?.text(0)
    }
}

/// The status of `id`'s next `finished` event.
private func finished(in events: AsyncStream<ConductorEvent>, _ id: DictationID) async -> DictationStatus? {
    for await event in events {
        if case .finished(id, let status) = event { return status }
    }
    return nil
}

/// Every notice up to and including `id`'s recovered notice.
private func notices(in events: AsyncStream<ConductorEvent>, until id: DictationID) async -> [Notice] {
    var seen: [Notice] = []
    for await event in events {
        guard case .notice(let notice) = event else { continue }
        seen.append(notice)
        if notice == .recovered(id) { break }
    }
    return seen
}
