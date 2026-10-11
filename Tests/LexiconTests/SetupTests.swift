import Testing
@testable import LexiconUI

// First-run setup's rules (#57): which step comes next, when the warning dot
// shows, when the window opens by itself, when the app relaunches, and what
// start at login does. The window, the System Settings panes and a real login
// are checked in the live app.

private func facts(microphone: MicrophoneAccess = .granted, accessibility: Bool = true, fnOn: Bool = true,
                   model: ModelState = .installed, triedFn: Bool = true) -> SetupFacts {
    SetupFacts(microphone: microphone, accessibility: accessibility, fnOn: fnOn, model: model,
               globeKeyOK: true, triedFn: triedFn)
}

@Test func aFreshMacStartsAtTheMicrophoneThenWalksTheStepsInOrder() {
    var mac = facts(microphone: .undetermined, accessibility: false, fnOn: false, model: .missing, triedFn: false)
    #expect(mac.current == .microphone)
    mac.microphone = .granted
    #expect(mac.current == .accessibility)
    mac.accessibility = true
    mac.fnOn = true
    #expect(mac.current == .model)
    mac.model = .downloading(0.4)
    #expect(mac.current == .model)
    mac.model = .installed
    #expect(mac.current == .tryFn)
    mac.triedFn = true
    #expect(mac.current == nil)
}

@Test func accessibilityIsNotDoneUntilTheFnTapRuns() {
    // Trusted, but the tap only starts at launch: the step waits for the relaunch.
    #expect(facts(accessibility: true, fnOn: false).current == .accessibility)
}

@Test func aMissingOrRevokedPermissionShowsTheDotAndPointsAtItsStep() {
    #expect(facts().warning == nil)
    #expect(facts(microphone: .denied).warning == .microphone)
    #expect(facts(microphone: .undetermined).warning == .microphone)
    #expect(facts(accessibility: false).warning == .accessibility)
    #expect(facts(fnOn: false).warning == .accessibility)
    #expect(facts(microphone: .denied, accessibility: false).warning == .microphone)
}

@Test func aMissingModelOrAnUntriedFnIsNoWarning() {
    #expect(facts(model: .missing, triedFn: false).warning == nil)
    #expect(facts(model: .privateMode).warning == nil)
}

@Test func theWindowOpensItselfOnlyOnFirstRunOrAfterTheAccessibilityRelaunch() {
    #expect(facts(microphone: .undetermined).opensAtLaunch(relaunched: false))
    #expect(facts(model: .missing).opensAtLaunch(relaunched: false))
    #expect(facts().opensAtLaunch(relaunched: true))
    // Set up before, permission revoked since: the dot, no popup.
    #expect(!facts(microphone: .denied).opensAtLaunch(relaunched: false))
    #expect(!facts(accessibility: false, fnOn: false).opensAtLaunch(relaunched: false))
    #expect(!facts().opensAtLaunch(relaunched: false))
}

@Test func trustAppearingRelaunchesOnceAndATrustedLaunchNeverDoes() {
    let untrusted = RelaunchRule(trustedAtLaunch: false)
    #expect(!untrusted.shouldRelaunch(trustedNow: false))
    #expect(untrusted.shouldRelaunch(trustedNow: true))
    // Trusted at launch with the tap still off: relaunching again could loop.
    #expect(!RelaunchRule(trustedAtLaunch: true).shouldRelaunch(trustedNow: true))
}

@Test func startAtLoginRegistersOnceAndLeavesJakesSystemSettingsChoiceAlone() {
    #expect(LoginItem.launchAction(wanted: true, status: .notRegistered) == .register)
    #expect(LoginItem.launchAction(wanted: true, status: .enabled) == nil)
    // Turned off in System Settings: never registered over.
    #expect(LoginItem.launchAction(wanted: true, status: .requiresApproval) == nil)
    // Turned off in Lexicon's menu.
    #expect(LoginItem.launchAction(wanted: false, status: .enabled) == .unregister)
    #expect(LoginItem.launchAction(wanted: false, status: .requiresApproval) == .unregister)
    #expect(LoginItem.launchAction(wanted: false, status: .notRegistered) == nil)
}

@Test func theMenuToggleFlipsStartAtLogin() {
    #expect(LoginItem.toggleAction(status: .notRegistered) == .register)
    #expect(LoginItem.toggleAction(status: .enabled) == .unregister)
    // Turned off in System Settings: only Jake can turn it back on, there.
    #expect(LoginItem.toggleAction(status: .requiresApproval) == .openSystemSettings)
}
