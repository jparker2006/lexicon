import Foundation
import Testing
import LexiconCore
import LexiconDomain

@Test func defaultsMatchTheSpec() {
    let defaults = Preferences.defaults
    #expect(defaults.raceDeadline == .milliseconds(300))
    #expect(defaults.cleanupDeadline == .milliseconds(450))
    #expect(defaults.cloudModel == nil)
    #expect(defaults.localModel == .parakeetUnified)
    #expect(defaults.speechTerms == 50)
    #expect(defaults.cleanupTerms == 200)
    #expect(defaults.localModelLinger == .seconds(600))
    #expect(defaults.aiCleanup)
    #expect(defaults.startAtLogin)
    #expect(defaults.soundsOn)
}

// Each store test gets a UserDefaults suite of its own and removes it at the end,
// so no test reads or writes Jake's settings.

@Test func updatePersistsForTheNextStore() {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }

    let first = PreferencesStore(defaults: suite)
    first.update { $0.soundsOn = false }

    let reopened = PreferencesStore(defaults: suite).snapshot()
    #expect(!reopened.soundsOn)
    #expect(reopened == first.snapshot())
}

@Test func aClearedSettingStaysClearedForTheNextStore() {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }

    PreferencesStore(defaults: suite).update { $0.localModel = nil }
    #expect(PreferencesStore(defaults: suite).snapshot().localModel == nil)
}

@Test func storedObjectMissingAFieldKeepsItsDefault() throws {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }

    var changed = Preferences.defaults
    changed.soundsOn = false
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
    object.removeValue(forKey: "startAtLogin")
    suite.set(try JSONSerialization.data(withJSONObject: object), forKey: "preferences")

    let loaded = PreferencesStore(defaults: suite).snapshot()
    #expect(loaded.startAtLogin == Preferences.defaults.startAtLogin)
    #expect(!loaded.soundsOn)
}

@Test func garbageUnderTheKeyLoadsTheDefaults() {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }

    suite.set(Data("not json {".utf8), forKey: "preferences")

    #expect(PreferencesStore(defaults: suite).snapshot() == Preferences.defaults)
}

@Test(.timeLimit(.minutes(1))) func changesYieldTheNewValue() async {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }

    let store = PreferencesStore(defaults: suite)
    let changes = store.changes()
    store.update { $0.soundsOn = false }

    // The stream buffers the newest value, so no waiting is needed.
    var iterator = changes.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.soundsOn == false)
}

@Test func microphoneFromLaunchArgumentIsForThisRunOnly() throws {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }

    suite.set("uid-from-args", forKey: "microphone")
    let store = PreferencesStore(defaults: suite)
    #expect(store.snapshot().microphoneUID == "uid-from-args")

    store.update { $0.soundsOn = false }
    #expect(store.snapshot().microphoneUID == "uid-from-args")

    let data = try #require(suite.data(forKey: "preferences"))
    let stored = try JSONDecoder().decode(Preferences.self, from: data)
    #expect(stored.microphoneUID == nil)
}

@Test func privateModeAndTheAlwaysPrivateListSurviveARelaunch() {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    #expect(Preferences.defaults.privacy == .standard)
    #expect(Preferences.defaults.alwaysPrivateApps.isEmpty)

    PreferencesStore(defaults: suite).update {
        $0.privacy = .private
        $0.alwaysPrivateApps = ["com.example.bank"]
    }

    // A quit and a reboot both come back through a new store on the same domain.
    let relaunched = PreferencesStore(defaults: suite).snapshot()
    #expect(relaunched.privacy == .private)
    #expect(relaunched.alwaysPrivateApps == ["com.example.bank"])
}
