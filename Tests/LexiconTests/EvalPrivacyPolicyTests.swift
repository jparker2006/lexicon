import Testing
import Synchronization
import LexiconDomain

private final class LookupCounter: Sendable {
    let calls = Mutex(0)
}

private func countedKeys(_ lookupCount: LookupCounter) -> @Sendable (CredentialID) -> String? {
    { _ in
        lookupCount.calls.withLock { $0 += 1 }
        return "synthetic-key"
    }
}

private func app(_ bundleID: String) -> AppContext {
    AppContext(bundleID: bundleID, appName: nil, windowTitle: nil, workingDirectory: nil)
}

@Test func unconfirmedMuseEvalIsDeniedBeforeLookingUpAKey() {
    let lookupCount = LookupCounter()
    let keys = countedKeys(lookupCount)

    #expect(Preferences.defaults.cloudDenied(for: .eval(.museVoice)) == .retentionUnconfirmed)
    #expect(CloudAccess.granted(by: .defaults, for: .eval(.museVoice), keys: keys) == nil)
    #expect(lookupCount.calls.withLock { $0 } == 0)
}

@Test func privateModeWinsForEveryCloudUseBeforeLookingUpAKey() {
    var preferences = Preferences.defaults
    preferences.privacy = .private
    preferences.alwaysPrivateApps = ["com.example.bank"]
    let uses: [CloudUse] = [
        .app(app("com.example.bank")),
        .modelInstall,
        .eval(.museVoice)
    ]

    let lookupCount = LookupCounter()
    let keys = countedKeys(lookupCount)
    for use in uses {
        #expect(preferences.cloudDenied(for: use) == .privateModeOn)
        #expect(CloudAccess.granted(by: preferences, for: use, keys: keys) == nil)
    }
    #expect(lookupCount.calls.withLock { $0 } == 0)
}

@Test func alwaysPrivateAppIsDeniedBeforeLookingUpAKey() {
    var preferences = Preferences.defaults
    preferences.alwaysPrivateApps = ["com.example.bank"]
    let use = CloudUse.app(app("com.example.bank"))

    let lookupCount = LookupCounter()
    #expect(preferences.cloudDenied(for: use) == .alwaysPrivateApp)
    #expect(CloudAccess.granted(by: preferences, for: use, keys: countedKeys(lookupCount)) == nil)
    #expect(lookupCount.calls.withLock { $0 } == 0)
}
