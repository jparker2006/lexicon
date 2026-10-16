import Testing
@testable import LexiconUI

// First-run setup's rules (#57): which step comes next, when the warning dot
// shows, when the window opens by itself, when the app relaunches, and what
// start at login does. The window, the System Settings panes and a real login
// are checked in the live app.

private func facts(microphone: MicrophoneAccess = .granted, accessibility: Bool = true, fnOn: Bool = true,
                   trustedAtLaunch: Bool = false, model: ModelState = .installed, triedFn: Bool = true) -> SetupFacts {
    SetupFacts(microphone: microphone, accessibility: accessibility, fnOn: fnOn, trustedAtLaunch: trustedAtLaunch,
               model: model, globeKeyOK: true, triedFn: triedFn)
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

@Test func trustAppearingRelaunchesAndATrustedLaunchNeverDoes() {
    let untrusted = RelaunchRule(trustedAtLaunch: false, fnOn: false)
    #expect(!untrusted.shouldRelaunch(trustedNow: false))
    #expect(untrusted.shouldRelaunch(trustedNow: true))
    // Trusted at launch with the tap still off: relaunching again could loop.
    #expect(!RelaunchRule(trustedAtLaunch: true, fnOn: false).shouldRelaunch(trustedNow: true))
    // A tap already running needs no relaunch, which would cut a Dictation it is recording.
    #expect(!RelaunchRule(trustedAtLaunch: false, fnOn: true).shouldRelaunch(trustedNow: true))
}

@Test func startAtLoginRegistersOnceAndLeavesJakesSystemSettingsChoiceAlone() {
    // First run.
    #expect(LoginItem.launchAction(wanted: true, offered: false, status: .notRegistered) == .register)
    #expect(LoginItem.launchAction(wanted: true, offered: true, status: .enabled) == nil)
    // Removed in System Settings after the first run (macOS 26 then reports notRegistered):
    // it stays removed.
    #expect(LoginItem.launchAction(wanted: true, offered: true, status: .notRegistered) == nil)
    // Switched off in System Settings: never registered over.
    #expect(LoginItem.launchAction(wanted: true, offered: true, status: .requiresApproval) == nil)
    // Turned off in Lexicon's menu.
    #expect(LoginItem.launchAction(wanted: false, offered: true, status: .enabled) == .unregister)
    #expect(LoginItem.launchAction(wanted: false, offered: true, status: .requiresApproval) == .unregister)
    #expect(LoginItem.launchAction(wanted: false, offered: true, status: .notRegistered) == nil)
}

@Test func aLoginItemFoundRegisteredSpendsTheFirstRunOffer() {
    // Turned on some other way (Jake added it in System Settings): removing it later must stick.
    #expect(LoginItem.offered(false, status: .enabled))
    #expect(LoginItem.offered(false, status: .requiresApproval))
    #expect(!LoginItem.offered(false, status: .notRegistered))
    #expect(LoginItem.offered(true, status: .notRegistered))
}

@Test func theMenuToggleFlipsStartAtLogin() {
    #expect(LoginItem.toggleAction(status: .notRegistered) == .register)
    #expect(LoginItem.toggleAction(status: .enabled) == .unregister)
    // Turned off in System Settings: only Jake can turn it back on, there.
    #expect(LoginItem.toggleAction(status: .requiresApproval) == .openSystemSettings)
}

@Test func aDoneStepHasNoButtonAndALaterStepWaits() {
    let mac = facts(microphone: .granted, accessibility: false, fnOn: false, model: .missing, triedFn: false)
    let microphone = SetupCopy.row(.microphone, mac)
    #expect(microphone.state == .done)
    #expect(microphone.button == nil)
    let accessibility = SetupCopy.row(.accessibility, mac)
    #expect(accessibility.state == .current)
    #expect(accessibility.button == "Open System Settings")
    #expect(SetupCopy.row(.model, mac).state == .waiting)
}

@Test func trustedButFnOffAsksForARestartAndThenForInputMonitoring() {
    let granted = SetupCopy.row(.accessibility, facts(accessibility: true, fnOn: false))
    #expect(granted.button == "Restart Lexicon")
    #expect(!granted.detail.contains("Input Monitoring"))
    // Restarted trusted and fn is still off: another restart alone won't help.
    let restarted = SetupCopy.row(.accessibility, facts(accessibility: true, fnOn: false, trustedAtLaunch: true))
    #expect(restarted.detail.contains("Input Monitoring"))
}

@Test func theModelRowShowsTheDownloadAndWhyItStopped() {
    // 0.57 * 100 is 56.99999999999999 in floating point.
    let downloading = SetupCopy.row(.model, facts(model: .downloading(0.57), triedFn: false))
    #expect(downloading.detail.contains("57%"))
    #expect(downloading.progress == 0.57)
    #expect(downloading.button == nil)
    #expect(SetupCopy.row(.model, facts(model: .privateMode)).detail.contains("Private mode"))
    #expect(SetupCopy.row(.model, facts(model: .failed)).button == "Try Again")
}

@Test func setupCopyHasNoEmDashes() {
    let all: [SetupFacts] = [
        facts(microphone: .undetermined, accessibility: false, fnOn: false, model: .missing, triedFn: false),
        facts(microphone: .denied, accessibility: true, fnOn: false, model: .downloading(0.5)),
        facts(model: .privateMode), facts(model: .failed), facts(),
    ]
    let words = all.flatMap { mac in SetupStep.allCases.map { SetupCopy.row($0, mac) } }
        .flatMap { [$0.title, $0.detail, $0.button ?? ""] }
        + [SetupCopy.globeKey(ok: false).detail, SetupCopy.globeKey(ok: true).detail]
        + SetupStep.allCases.flatMap { [SetupCopy.warningMenuTitle($0), SetupCopy.warningLabel($0)] }
    #expect(!words.contains { $0.contains("\u{2014}") })
}

@Test func aRelaunchThatFailedToStartCanBeRetriedByRestartButNotByThePoll() {
    var gate = RelaunchGate()
    let first = gate.begin(byJake: false)
    // One at a time.
    let whileStarting = gate.begin(byJake: true)
    gate.failed()
    // The poll would otherwise retry, and log a failure, every second.
    let pollAfterFailure = gate.begin(byJake: false)
    // Restart works again.
    let restartAfterFailure = gate.begin(byJake: true)
    #expect(first)
    #expect(!whileStarting)
    #expect(!pollAfterFailure)
    #expect(restartAfterFailure)
}

// The setup menu's lines: each missing permission gets its own line, so
// the menu names every thing to fix instead of only the dot's first one. The model
// line appears only once the permissions are fine, so the menu never offers a
// download before Jake can dictate with it.

@Test func bothMissingPermissionsGetAMenuLineEachInOrder() {
    // Denied and not yet asked both count as off.
    for microphone in [MicrophoneAccess.denied, .undetermined] {
        let mac = facts(microphone: microphone, accessibility: false)
        #expect(mac.menuSteps == [.microphone, .accessibility])
        // The dot still points at the first missing step; the menu lists both.
        #expect(mac.warning == .microphone)
    }
    #expect(SetupCopy.warningMenuTitle(.microphone) == "Microphone is off: Set Up…")
    #expect(SetupCopy.warningMenuTitle(.accessibility) == "fn is off: Set Up…")
}

@Test func oneMissingPermissionGetsOnlyItsOwnMenuLine() {
    #expect(facts(microphone: .denied).menuSteps == [.microphone])
    #expect(facts(microphone: .undetermined).menuSteps == [.microphone])
    #expect(facts(accessibility: false).menuSteps == [.accessibility])
    #expect(facts(fnOn: false).menuSteps == [.accessibility])
    // A missing model waits behind a missing permission, so the menu names the permission only.
    #expect(facts(microphone: .denied, model: .missing).menuSteps == [.microphone])
}

@Test func aMissingModelIsTheOnlyMenuLineOnceThePermissionsAreFine() {
    #expect(facts(model: .missing).menuSteps == [.model])
    #expect(SetupCopy.warningMenuTitle(.model) == "Set Up Lexicon…")
}

@Test func aFinishedSetupHasNoMenuLines() {
    #expect(facts().menuSteps == [])
}

@Test func thePreparingModelRowSaysPreparingWithNoBarOrButton() {
    // The download is over and CoreML is still preparing the model: not a download, not done.
    let preparing = facts(model: .preparing)
    let row = SetupCopy.row(.model, preparing)
    #expect(row.detail == "Preparing the model.")
    #expect(row.progress == nil)
    #expect(row.button == nil)
    #expect(!preparing.isDone(.model))
    #expect(preparing.current == .model)
}

@Test func aDownloadShowsItsWholePercentAndAProgressBar() {
    let row = SetupCopy.row(.model, facts(model: .downloading(0.42)))
    #expect(row.detail == "Downloading, 42%.")
    #expect(row.progress == 0.42)
}

@Test func onlyADownloadingModelSaysDownloading() {
    // "Downloading" describes the file transfer alone; the Preparing step after it must not read as one.
    let others: [ModelState] = [.missing, .preparing, .installed, .privateMode, .failed]
    for state in others {
        let detail = SetupCopy.row(.model, facts(model: state)).detail
        #expect(!detail.hasPrefix("Downloading"))
    }
}
