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

// #82: the connection warm-up (a keyless HEAD to Jev) runs only for a Re-speak or a
// Hand-fix watch. A plain Dictation sends nothing to Jev. The real Conductor on a
// synthesized WAV, a scripted engine, and a fake TypeSafe server. No mic, keys or network.

private let spoken = "Um, so can you, uh, refactor the useAuth hook so it it doesn't re-render on every keystroke?"

@Test(.timeLimit(.minutes(1))) func plainDictationSendsNothingToJev() async throws {
    let paths = AppPaths.temporary()
    let server = FakeJev()
    let conductor = Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: spoken), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: try HistoryStore(paths: paths),
        destination: HeadlessDestination(), preferences: PreferencesStore(fixed: .defaults),
        secrets: Secrets(.environment), keyboard: nil, fixes: nil,
        jev: JevClient(session: server.session, clock: TestClock(), requestTimeout: 3_600))

    // Plain Dictation first. If it warmed Jev, its HEAD would already be on its way
    // when the Re-speak starts, so the first arrival below would be the plain one's.
    let plain = await conductor.dictate(file: try writeWAV(syntheticSamples(count: 8_000), rate: 16_000,
                                                           in: try scratchDirectory()),
                                        pace: .asFastAsPossible)
    _ = await conductor.dictate(file: try writeWAV(syntheticSamples(count: 8_000), rate: 16_000,
                                                   in: try scratchDirectory()),
                                pace: .asFastAsPossible, purpose: .respeak(of: plain.id))

    // The Re-speak's prewarm is the one HEAD this test expects. Wait for its arrival
    // (the time limit stops a hang), then check nothing else reached Jev.
    for await _ in server.arrived { break }
    #expect(server.requests.count == 1)
    #expect(server.requests.first?.method == "HEAD")
}
