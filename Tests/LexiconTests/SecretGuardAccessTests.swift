import Synchronization
import Testing
import LexiconDomain

@Test func appTextAccessRevokesBeforeLookingUpSecretAndKeepsProseAvailable() throws {
    let secret = "qjvmxkztbdrphwnslfygcauo"
    let secretLookups = Mutex(0)
    let secretAccess = try #require(CloudAccess.granted(by: .defaults, for: .app(.unknown)) { _ in
        secretLookups.withLock { $0 += 1 }
        return "synthetic-credential"
    })

    #expect(secretAccess.key(.cleanup, sending: "Use \(secret) for the release.") == nil)
    #expect(secretAccess.revoked == .secretFound)
    #expect(secretLookups.withLock { $0 } == 0)

    #expect(secretAccess.key(.cleanup) == nil)
    #expect(secretAccess.key(.jev, sending: "Please summarize this release note.") == nil)
    #expect(secretLookups.withLock { $0 } == 0)

    let proseLookups = Mutex(0)
    let proseAccess = try #require(CloudAccess.granted(by: .defaults, for: .app(.unknown)) { _ in
        proseLookups.withLock { $0 += 1 }
        return "synthetic-credential"
    })

    #expect(proseAccess.key(.cleanup, sending: "Please summarize this release note.") == "synthetic-credential")
    #expect(proseLookups.withLock { $0 } == 1)
}
