import Testing
import LexiconDomain

// Fake keys only: the lookup hands back a made-up value for every credential.
private let fakeKeys: @Sendable (CredentialID) -> String? = { "fake-key-for-" + $0.account }
private let fakeSecret = "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4"

private func access(_ preferences: Preferences = .defaults, app: AppContext = .unknown) throws -> CloudAccess {
    try #require(CloudAccess.granted(by: preferences, for: .app(app), keys: fakeKeys))
}

@Test func privateModeAndAlwaysPrivateAppsGetNoAccess() throws {
    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    #expect(CloudAccess.granted(by: privateMode, for: .app(.unknown), keys: fakeKeys) == nil)

    var alwaysPrivate = Preferences.defaults
    alwaysPrivate.alwaysPrivateApps = ["com.example.bank"]
    let bank = AppContext(bundleID: "com.example.bank", appName: nil, windowTitle: nil, workingDirectory: nil)
    let editor = AppContext(bundleID: "com.example.editor", appName: nil, windowTitle: nil, workingDirectory: nil)
    #expect(CloudAccess.granted(by: alwaysPrivate, for: .app(bank), keys: fakeKeys) == nil)
    #expect(try access(alwaysPrivate, app: editor).key(.jev) == "fake-key-for-jev")
}

@Test func anAppLexiconCannotNameFailsClosedOnceTheListHasAnyApp() throws {
    var alwaysPrivate = Preferences.defaults
    alwaysPrivate.alwaysPrivateApps = ["com.example.bank"]
    #expect(CloudAccess.granted(by: alwaysPrivate, for: .app(.unknown), keys: fakeKeys) == nil)
    #expect(alwaysPrivate.cloudDenied(for: .app(.unknown)) == .alwaysPrivateApp)
    // With an empty list no app is private, so an unnamed one is no risk.
    #expect(Preferences.defaults.cloudDenied(for: .app(.unknown)) == nil)
}

@Test func modelInstallIsStoppedByPrivateModeButNotByTheAppList() throws {
    var alwaysPrivate = Preferences.defaults
    alwaysPrivate.alwaysPrivateApps = ["com.example.bank"]
    #expect(CloudAccess.granted(by: alwaysPrivate, for: .modelInstall, keys: fakeKeys) != nil)

    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    #expect(CloudAccess.granted(by: privateMode, for: .modelInstall, keys: fakeKeys) == nil)
    #expect(privateMode.cloudDenied(for: .modelInstall) == .privateModeOn)
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

/// Every model whose zero-retention is not confirmed yet. Read from the model
/// list, so no model's retention value is pinned here.
private var unconfirmedModels: [CloudModel] { CloudModel.allCases.filter { $0.retention == .unconfirmed } }

@Test func anEvalToAnUnconfirmedRetentionModelIsDeniedWithTheGatesReason() throws {
    try #require(!unconfirmedModels.isEmpty)
    for model in unconfirmedModels {
        #expect(Preferences.defaults.cloudDenied(for: .eval(model)) == .retentionUnconfirmed)
        #expect(CloudAccess.granted(by: .defaults, for: .eval(model), keys: fakeKeys) == nil)
    }
}

@Test func privateModeIsCheckedFirstAndTheRetentionGateLeavesDailyDictationAlone() throws {
    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    try #require(!unconfirmedModels.isEmpty)
    for model in unconfirmedModels {
        #expect(privateMode.cloudDenied(for: .eval(model)) == .privateModeOn)
    }
    // The gate covers evals only: an app dictation with defaults is still granted.
    #expect(Preferences.defaults.cloudDenied(for: .app(.unknown)) == nil)
    #expect(try access().key(.cleanup, sending: "An ordinary sentence.") == "fake-key-for-cleanup.openrouter")
}
