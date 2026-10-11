import Testing
import LexiconDomain
@testable import Transcription

// The race's decision table and the local model's residency rule, both pure: no
// clock, no model, no network. The engines' timing is tested headless in CloudRaceTests.

private struct RaceCase: Sendable, CustomTestStringConvertible {
    let name: String
    let cloud: RacePolicy.State?
    let local: RacePolicy.State?
    let deadlinePassed: Bool
    let expected: RacePolicy.Decision
    var testDescription: String { name }
}

private let raceCases = [
    RaceCase(name: "cloud final before the deadline wins over a local that is done",
            cloud: .done("cloud"), local: .done("local"), deadlinePassed: false, expected: .useCloud),
    RaceCase(name: "cloud final wins while local is still pending",
            cloud: .done("cloud"), local: .pending, deadlinePassed: false, expected: .useCloud),
    RaceCase(name: "local is done early: wait for the cloud",
            cloud: .pending, local: .done("local"), deadlinePassed: false, expected: .wait),
    RaceCase(name: "local is done after the deadline: use it",
            cloud: .pending, local: .done("local"), deadlinePassed: true, expected: .useLocal),
    RaceCase(name: "failed cloud hands over to local at once",
            cloud: .failed, local: .done("local"), deadlinePassed: false, expected: .useLocal),
    RaceCase(name: "failed cloud with local still pending: wait for local",
            cloud: .failed, local: .pending, deadlinePassed: false, expected: .wait),
    RaceCase(name: "local failed after the deadline: the cloud is the only hope",
            cloud: .pending, local: .failed, deadlinePassed: true, expected: .wait),
    RaceCase(name: "both failed: nothing yet",
            cloud: .failed, local: .failed, deadlinePassed: false, expected: .nothingYet),
    RaceCase(name: "no cloud, local done: use local",
            cloud: nil, local: .done("local"), deadlinePassed: false, expected: .useLocal),
    RaceCase(name: "no cloud, local pending: wait for local",
            cloud: nil, local: .pending, deadlinePassed: false, expected: .wait),
    RaceCase(name: "no cloud, local failed: nothing yet",
            cloud: nil, local: .failed, deadlinePassed: false, expected: .nothingYet),
    RaceCase(name: "cloud done, no local: use cloud",
            cloud: .done("cloud"), local: nil, deadlinePassed: false, expected: .useCloud),
    RaceCase(name: "cloud pending, no local, deadline passed: wait for the cloud",
            cloud: .pending, local: nil, deadlinePassed: true, expected: .wait),
    RaceCase(name: "cloud failed, no local: nothing yet",
            cloud: .failed, local: nil, deadlinePassed: false, expected: .nothingYet),
    RaceCase(name: "no engines in the plan: nothing yet",
            cloud: nil, local: nil, deadlinePassed: false, expected: .nothingYet),
]

/// `decide` takes no clock: the caller says whether the deadline has passed, so the
/// deadline's value is never read here.
@Test(arguments: raceCases)
private func theRaceDecidesWhichFinalToUse(_ c: RaceCase) {
    let race = RacePolicy(deadline: .zero)
    #expect(race.decide(cloud: c.cloud, local: c.local, deadlinePassed: c.deadlinePassed) == c.expected)
}

private func unloadAfter(cloud: CloudModel?, privacy: PrivacyMode = .standard, reachable: Bool) -> Duration? {
    var preferences = Preferences.defaults
    preferences.cloudModel = cloud
    preferences.privacy = privacy
    var policy = ResidencyPolicy(preferences)
    policy.networkReachable = reachable
    return policy.unloadAfter
}

@Test func theLocalModelLingersUnlessPrivateOrCutOffFromTheCloud() {
    let linger = Preferences.defaults.localModelLinger

    // With no cloud model the network takes nothing away, so reachability does not count.
    #expect(unloadAfter(cloud: nil, reachable: false) == linger)
    #expect(unloadAfter(cloud: nil, reachable: true) == linger)

    // A cloud model cannot be reached offline, so local stays resident only then.
    #expect(unloadAfter(cloud: .museVoice, reachable: true) == linger)
    #expect(unloadAfter(cloud: .museVoice, reachable: false) == nil)

    // Private mode keeps local resident whatever the cloud and the network are doing.
    #expect(unloadAfter(cloud: nil, privacy: .private, reachable: true) == nil)
    #expect(unloadAfter(cloud: .museVoice, privacy: .private, reachable: true) == nil)
    #expect(unloadAfter(cloud: .museVoice, privacy: .private, reachable: false) == nil)
}
