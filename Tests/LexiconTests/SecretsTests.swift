import Foundation
import Testing
import LexiconCore
import LexiconDomain

// Fake keys only. The Keychain tests use a throwaway service per test, never a
// Lexicon bundle ID, and remove their item when they finish.

private func throwawayService() -> String { "dev.jparker.lexicon.tests.\(UUID().uuidString)" }

private func outcome(from command: CredentialCommand, for edit: CredentialEdit) async -> CredentialOutcome {
    await withCheckedContinuation { continuation in
        command(edit) { continuation.resume(returning: $0) }
    }
}

@Test func aKeySetInTheKeychainIsReadBackAndDeleted() async {
    let service = throwawayService()
    let secrets = Secrets(.keychain(service: service))
    let command = secrets.credentials

    let lookupStartedMissing = secrets.lookup(.jev) == nil
    let saved = await outcome(from: command, for: .save(.jev, "fake-jev-key"))
    let lookupSawSavedValue = secrets.lookup(.jev) == "fake-jev-key"
    let freshOwnerSawSavedValue = Secrets(.keychain(service: service)).lookup(.jev) == "fake-jev-key"

    let replaced = await outcome(from: command, for: .save(.jev, "fake-jev-key-2"))
    let freshOwnerSawReplacement = Secrets(.keychain(service: service)).lookup(.jev) == "fake-jev-key-2"
    let removed = await outcome(from: command, for: .remove(.jev))
    let cachedLookupSawMissing = secrets.lookup(.jev) == nil
    let freshOwnerSawMissing = Secrets(.keychain(service: service)).lookup(.jev) == nil

    #expect(lookupStartedMissing)
    #expect(saved == .saved)
    #expect(lookupSawSavedValue)
    #expect(freshOwnerSawSavedValue)
    #expect(replaced == .saved)
    #expect(freshOwnerSawReplacement)
    #expect(removed == .removed)
    #expect(cachedLookupSawMissing)
    #expect(freshOwnerSawMissing)
}

@Test func keysAreReadOnceAndKeptInMemory() async {
    let service = throwawayService()
    let writer = Secrets(.keychain(service: service))
    let writerCommand = writer.credentials
    let reader = Secrets(.keychain(service: service))
    let readerCommand = reader.credentials

    let saved = await outcome(from: writerCommand, for: .save(.cleanup, "fake-openrouter-key"))
    let readerSawSavedValue = reader.lookup(.cleanup) == "fake-openrouter-key"
    let removed = await outcome(from: writerCommand, for: .remove(.cleanup))
    let readerKeptItsCachedValue = reader.lookup(.cleanup) == "fake-openrouter-key"
    let readerCleanup = await outcome(from: readerCommand, for: .remove(.cleanup))

    #expect(saved == .saved)
    #expect(readerSawSavedValue)
    #expect(removed == .removed)
    #expect(readerKeptItsCachedValue)
    #expect(readerCleanup == .removed)
}

@Test func eachCredentialIsItsOwnItem() async {
    let service = throwawayService()
    let secrets = Secrets(.keychain(service: service))
    let command = secrets.credentials
    let speechSave = await outcome(from: command, for: .save(.speech(.museVoice), "fake-meta-key"))
    let cleanupSave = await outcome(from: command, for: .save(.cleanup, "fake-openrouter-key"))

    let fresh = Secrets(.keychain(service: service))
    let speechItemWasSaved = fresh.lookup(.speech(.museVoice)) == "fake-meta-key"
    let cleanupItemWasSaved = fresh.lookup(.cleanup) == "fake-openrouter-key"
    let jevWasMissing = fresh.lookup(.jev) == nil
    let removedSpeech = await outcome(from: command, for: .remove(.speech(.museVoice)))
    let removedCleanup = await outcome(from: command, for: .remove(.cleanup))
    let removedJev = await outcome(from: command, for: .remove(.jev))

    #expect(speechSave == .saved)
    #expect(cleanupSave == .saved)
    #expect(speechItemWasSaved)
    #expect(cleanupItemWasSaved)
    #expect(jevWasMissing)
    #expect(removedSpeech == .removed)
    #expect(removedCleanup == .removed)
    #expect(removedJev == .removed)
}
