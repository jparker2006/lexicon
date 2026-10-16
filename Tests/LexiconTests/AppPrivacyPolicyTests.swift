import Synchronization
import Testing
import LexiconDomain

private func appContext(_ bundleID: String?) -> AppContext {
    AppContext(bundleID: bundleID, appName: nil, windowTitle: nil, workingDirectory: nil)
}

private final class LookupCounter: Sendable {
    let calls = Mutex(0)
}

private func countedKeys(_ lookups: LookupCounter) -> @Sendable (CredentialID) -> String? {
    { _ in
        lookups.calls.withLock { $0 += 1 }
        return "synthetic-key"
    }
}

@Test func alwaysPrivateAppMatchingIgnoresBundleIDCaseOnEitherSide() {
    let pairs = [
        (privateID: "com.example.bank", activeID: "COM.EXAMPLE.BANK"),
        (privateID: "COM.EXAMPLE.BANK", activeID: "com.example.bank"),
    ]

    for pair in pairs {
        var preferences = Preferences.defaults
        preferences.alwaysPrivateApps = [pair.privateID]
        let app = appContext(pair.activeID)
        let lookups = LookupCounter()

        #expect(preferences.cloudDenied(for: .app(app)) == .alwaysPrivateApp)
        #expect(CloudAccess.granted(by: preferences, for: .app(app), keys: countedKeys(lookups)) == nil)
        #expect(lookups.calls.withLock { $0 } == 0)
    }
}

@Test func appPrivacyKeepsPunctuationAndWhitespaceSignificant() {
    var preferences = Preferences.defaults
    preferences.alwaysPrivateApps = ["com.example.bank"]

    for bundleID in ["com-example.bank", "com.example.banks", " com.example.bank", "com.example.bank "] {
        let app = appContext(bundleID)
        let lookups = LookupCounter()

        #expect(preferences.cloudDenied(for: .app(app)) == nil)
        let access = CloudAccess.granted(by: preferences, for: .app(app), keys: countedKeys(lookups))
        #expect(access?.key(.jev) == "synthetic-key")
        #expect(lookups.calls.withLock { $0 } == 1)
    }
}

@Test func emptyAndNonemptyPrivateListsHandleUnknownAppsDifferently() {
    let unknown = appContext(nil)
    let emptyListLookups = LookupCounter()

    #expect(Preferences.defaults.cloudDenied(for: .app(unknown)) == nil)
    let emptyListAccess = CloudAccess.granted(by: .defaults, for: .app(unknown), keys: countedKeys(emptyListLookups))
    #expect(emptyListAccess?.key(.jev) == "synthetic-key")
    #expect(emptyListLookups.calls.withLock { $0 } == 1)

    var nonemptyList = Preferences.defaults
    nonemptyList.alwaysPrivateApps = ["com.example.bank"]
    let nonemptyListLookups = LookupCounter()

    #expect(nonemptyList.cloudDenied(for: .app(unknown)) == .alwaysPrivateApp)
    #expect(CloudAccess.granted(by: nonemptyList, for: .app(unknown), keys: countedKeys(nonemptyListLookups)) == nil)
    #expect(nonemptyListLookups.calls.withLock { $0 } == 0)
}

@Test func privateModeDeniesEveryAppBeforeLookingUpAKey() {
    var preferences = Preferences.defaults
    preferences.privacy = .private
    preferences.alwaysPrivateApps = ["com.example.bank"]

    for app in [appContext("com.example.editor"), appContext(nil)] {
        let lookups = LookupCounter()

        #expect(preferences.cloudDenied(for: .app(app)) == .privateModeOn)
        #expect(CloudAccess.granted(by: preferences, for: .app(app), keys: countedKeys(lookups)) == nil)
        #expect(lookups.calls.withLock { $0 } == 0)
    }
}
