import Foundation
import Testing
import LexiconCore
import LexiconDomain

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
