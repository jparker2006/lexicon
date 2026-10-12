import Foundation
import Testing
@testable import AudioCapture
@testable import Jev
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// The connection warm-up (a keyless HEAD to Jev) runs only for a Re-speak or a
// Hand-fix watch. A plain Dictation sends nothing to Jev. The real Conductor on a
// synthesized WAV, a scripted engine, and a fake TypeSafe server. No mic, keys or network.

private let spoken = "Um, so can you, uh, refactor the useAuth hook so it it doesn't re-render on every keystroke?"

/// A Conductor whose Jev talks to `server`.
private func conductor(_ server: FakeJev) throws -> Conductor<HeadlessDestination> {
    let paths = AppPaths.temporary()
    return Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: spoken), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: try HistoryStore(paths: paths),
        destination: HeadlessDestination(), preferences: PreferencesStore(fixed: .defaults),
        secrets: Secrets(.environment), keyboard: nil, fixes: nil,
        jev: JevClient(session: server.session, clock: TestClock(), requestTimeout: 3_600))
}

@Test(.timeLimit(.minutes(1))) func plainDictationSendsNothingToJev() async throws {
    // Each Dictation has its own Jev server, so the Re-speak's HEAD is told apart
    // from any the plain Dictation sent.
    let plainServer = FakeJev(), respeakServer = FakeJev()
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())

    // The plain Dictation runs to the end first, so a HEAD it sent would have
    // started before the Re-speak's, and arrived by the time the Re-speak's has.
    let plain = try await conductor(plainServer).dictate(file: wav, pace: .asFastAsPossible)
    _ = try await conductor(respeakServer).dictate(file: wav, pace: .asFastAsPossible,
                                                   purpose: .respeak(of: plain.id))

    for await _ in respeakServer.arrived { break }  // the time limit stops a hang
    #expect(respeakServer.requests.map(\.method) == ["HEAD"])
    #expect(plainServer.requests.isEmpty)
}
