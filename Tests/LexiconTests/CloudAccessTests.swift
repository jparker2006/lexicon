import Testing
import LexiconDomain

// Fake keys only: the lookup hands back a made-up value for every credential.
private let fakeKeys: @Sendable (CredentialID) -> String? = { "fake-key-for-" + $0.account }
private let fakeSecret = "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4"

private func access(_ preferences: Preferences = .defaults, app: AppContext = .unknown) throws -> CloudAccess {
    try #require(CloudAccess.granted(by: preferences, app: app, keys: fakeKeys))
}

@Test func privateModeAndAlwaysPrivateAppsGetNoAccess() throws {
    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    #expect(CloudAccess.granted(by: privateMode, app: .unknown, keys: fakeKeys) == nil)

    var alwaysPrivate = Preferences.defaults
    alwaysPrivate.alwaysPrivateApps = ["com.example.bank"]
    let bank = AppContext(bundleID: "com.example.bank", appName: nil, windowTitle: nil, workingDirectory: nil)
    let editor = AppContext(bundleID: "com.example.editor", appName: nil, windowTitle: nil, workingDirectory: nil)
    #expect(CloudAccess.granted(by: alwaysPrivate, app: bank, keys: fakeKeys) == nil)
    #expect(try access(alwaysPrivate, app: editor).key(.jev) == "fake-key-for-jev")
}

@Test func aTextCallWithASecretGetsNoKeyAndLaterCallsGetNothing() throws {
    let access = try access()
    #expect(access.key(.cleanup, sending: "Can you tidy this paragraph?") == "fake-key-for-cleanup.openrouter")

    #expect(access.key(.cleanup, sending: "Use \(fakeSecret) for the deploy.") == nil)
    #expect(access.revoked == .secretFound)

    #expect(access.key(.cleanup, sending: "An ordinary sentence.") == nil)
    #expect(access.key(.jev, sending: "An ordinary sentence.") == nil)
    #expect(access.key(.speech(.museVoice)) == nil)
}

@Test func theFirstRevokeReasonWins() throws {
    let access = try access()
    access.revoke(.privateModeOn)
    access.revoke(.secretFound)
    _ = access.key(.cleanup, sending: fakeSecret)
    #expect(access.revoked == .privateModeOn)
    #expect(access.key(.speech(.museVoice)) == nil)
}

@Test func waitersResumeWhenAccessIsRevoked() async throws {
    let access = try access()
    async let first = access.whenRevoked()
    async let second = access.whenRevoked()
    // Revoking before either waiter registers is fine too: a late waiter returns at once.
    access.revoke(.alwaysPrivateApp)
    #expect(await first == .alwaysPrivateApp)
    #expect(await second == .alwaysPrivateApp)
    #expect(await access.whenRevoked() == .alwaysPrivateApp)
}

@Test func aCancelledWaiterReturnsNilAndAccessStaysGranted() async throws {
    let access = try access()
    let waiter = Task { await access.whenRevoked() }
    waiter.cancel()
    #expect(await waiter.value == nil)
    #expect(access.revoked == nil)
    #expect(access.key(.jev) == "fake-key-for-jev")
}

@Test func aSpeechSessionRacingRevocationStopsTheMomentAccessEnds() async throws {
    let access = try access()
    let (socket, closeSocket) = AsyncStream<Void>.makeStream()
    let ended = Task {
        // The shape a speech session uses: whichever finishes first wins, the other is cancelled.
        await withTaskGroup(of: String.self) { group in
            group.addTask { for await _ in socket {}; return "socket closed" }
            group.addTask { await access.whenRevoked().map { "revoked: \($0)" } ?? "cancelled" }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
    access.revoke(.secretFound)
    #expect(await ended.value == "revoked: secretFound")
    closeSocket.finish()
}
