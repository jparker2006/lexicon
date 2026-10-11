import Foundation
import Testing
@testable import LexiconCore
import AudioCapture
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// Fake keys only. The Keychain tests use a throwaway service per test, never a
// Lexicon bundle ID, and delete their item when they finish.

private func throwawayService() -> String { "dev.jparker.lexicon.tests.\(UUID().uuidString)" }

@Test func aKeySetInTheKeychainIsReadBackAndDeleted() throws {
    let service = throwawayService()
    let secrets = Secrets(.keychain(service: service))
    defer { try? secrets.set(nil, for: .jev) }

    #expect(secrets.lookup(.jev) == nil)
    try secrets.set("fake-jev-key", for: .jev)
    #expect(secrets.lookup(.jev) == "fake-jev-key")
    #expect(Secrets(.keychain(service: service)).lookup(.jev) == "fake-jev-key")

    try secrets.set("fake-jev-key-2", for: .jev)
    #expect(Secrets(.keychain(service: service)).lookup(.jev) == "fake-jev-key-2")

    try secrets.set(nil, for: .jev)
    #expect(secrets.lookup(.jev) == nil)
    #expect(Secrets(.keychain(service: service)).lookup(.jev) == nil)
}

@Test func keysAreReadOnceAndKeptInMemory() throws {
    let service = throwawayService()
    let writer = Secrets(.keychain(service: service))
    defer { try? writer.set(nil, for: .cleanup) }
    try writer.set("fake-openrouter-key", for: .cleanup)

    let reader = Secrets(.keychain(service: service))
    #expect(reader.lookup(.cleanup) == "fake-openrouter-key")
    try writer.set(nil, for: .cleanup)
    #expect(reader.lookup(.cleanup) == "fake-openrouter-key")
}

@Test func eachCredentialIsItsOwnItem() throws {
    let service = throwawayService()
    let secrets = Secrets(.keychain(service: service))
    defer {
        for id in [CredentialID.speech(.museVoice), .cleanup, .jev] { try? secrets.set(nil, for: id) }
    }
    try secrets.set("fake-meta-key", for: .speech(.museVoice))
    try secrets.set("fake-openrouter-key", for: .cleanup)

    let fresh = Secrets(.keychain(service: service))
    #expect(fresh.lookup(.speech(.museVoice)) == "fake-meta-key")
    #expect(fresh.lookup(.cleanup) == "fake-openrouter-key")
    #expect(fresh.lookup(.jev) == nil)
}

// The log half of "never logged" is checked on a test run's logs, not here:
// reading this process's log through OSLogStore takes about 10 s.
@Test func keysNeverReachHistory() async throws {
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let fakeKey = "fake-key-65-never-stored"
    let secrets = Secrets(.keychain(service: throwawayService()))
    defer { try? secrets.set(nil, for: .cleanup) }
    try secrets.set(fakeKey, for: .cleanup)
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let conductor = Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: "dictation sixty five never logged")),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: HeadlessDestination(),
        preferences: PreferencesStore(fixed: .defaults), secrets: secrets,
        keyboard: nil, fixes: nil, jev: nil)

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()
    #expect(result.status == .inserted)

    let files = FileManager.default.enumerator(at: paths.root, includingPropertiesForKeys: nil)!.allObjects
    let stored = files.compactMap { try? Data(contentsOf: $0 as! URL) }.reduce(Data(), +)
    #expect(!stored.isEmpty)
    #expect(stored.range(of: Data(fakeKey.utf8)) == nil)
}
