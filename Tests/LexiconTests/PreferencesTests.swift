import Testing
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
}
