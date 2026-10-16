import Foundation
import Synchronization
import Testing
import LexiconCore
import LexiconDomain
@testable import LexiconUI

// First-run setup's Accessibility relaunch and model download, through fake
// `Setup.Services`: no permission is asked, no login item is touched, no network
// is used. `start()` is never called, so the poll timer never runs; each test
// makes its own polls with `refresh()`.

/// The system's answers, as the fake services read them. The trust and Microphone
/// reads run off the main thread, so every answer sits behind one lock.
private struct Answers: Sendable {  // Mutex-guarded: read by the services off the main thread
    var trusted = false
    var microphone = MicrophoneAccess.undetermined
    var modelInstalled = false
    var relaunches = 0
    var microphoneGrants = 0
    var installs = 0
}

private final class Machine: Sendable {
    private let answers = Mutex(Answers())

    func read<T>(_ body: (Answers) -> T) -> T { answers.withLock { body($0) } }
    func write(_ body: (inout Answers) -> Void) { answers.withLock { body(&$0) } }

    var installs: Int { read { $0.installs } }
    var relaunches: Int { read { $0.relaunches } }
    var microphoneGrants: Int { read { $0.microphoneGrants } }
}

/// A one-shot signal. `wait()` returns once `open()` has run, even when `open()`
/// came first: the stream holds the signal until someone asks for it.
private struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() { (stream, signal) = AsyncStream<Void>.makeStream() }

    func open() { signal.yield() }
    func wait() async { for await _ in stream { return } }
}

/// What `Setup` calls to download the model.
private typealias Install = @Sendable (CloudAccess, @escaping @Sendable (ModelInstallProgress) -> Void) async throws -> Void

/// The setup window, recording what it was asked to draw. It never shows.
@MainActor
private final class FakeWindow: SetupWindowShowing {
    private(set) var renders: [SetupFacts] = []
    var dictationLandedHere = false

    func render(_ facts: SetupFacts) { renders.append(facts) }
    func focus(_ step: SetupStep?) {}
}

/// A download that finishes at once, for the tests that only watch the permissions.
private func finishingInstall(_ machine: Machine) -> Install {
    { _, _ in machine.write { $0.installs += 1 } }
}

@MainActor
private func makeServices(_ machine: Machine, fnOn: Bool, install: @escaping Install) -> Setup.Services {
    Setup.Services(
        fnOn: fnOn,
        globeKeyOK: { true },
        modelInstalled: { machine.read { $0.modelInstalled } },
        installModel: install,
        modelInstalledNow: {},
        microphoneGranted: { machine.write { $0.microphoneGrants += 1 } },
        accessibilityTrusted: { machine.read { $0.trusted } },
        microphone: { machine.read { $0.microphone } },
        relaunch: { machine.write { $0.relaunches += 1 } })
}

/// A `Setup` over `machine`, with the status item and preferences the other UI tests
/// build (Private mode off). The login item is never touched: `start()` is never called.
@MainActor
private func withSetup(_ machine: Machine, fnOn: Bool, install: @escaping Install,
                       _ body: @MainActor (Setup) async -> Void) async {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    let status = StatusItemController(appName: "Lexicon", version: "test")
    defer { status.item.statusBar?.removeStatusItem(status.item) }
    let setup = Setup(statusItem: status, preferences: PreferencesStore(defaults: suite),
                      services: makeServices(machine, fnOn: fnOn, install: install),
                      relaunched: false, registersAtLogin: false)
    await body(setup)
}

/// Polls until `condition` holds, and returns whether it did. Model progress arrives
/// on a background task and hops here, and nothing signals the test when the facts
/// change. The bound is a hang guard only: 10 s is far longer than any hop takes, so
/// a stuck state fails the check instead of hanging the run.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))  // timing-ok: a poll interval; the 10 s bound is only a hang guard
    }
    return condition()
}

// Criterion 4: a launch that began untrusted relaunches exactly once, when trust appears.
@MainActor
@Test func anUntrustedLaunchRelaunchesOnceWhenTrustAppears() async {
    let machine = Machine()  // Accessibility not trusted at launch, so Setup reads it that way
    await withSetup(machine, fnOn: false, install: finishingInstall(machine)) { setup in
        await setup.refresh()
        #expect(machine.relaunches == 0, "no relaunch while Accessibility is still off")

        machine.write { $0.trusted = true }
        await setup.refresh()
        #expect(machine.relaunches == 1, "the grant relaunches the app once")

        // The relaunch is already under way (the app quits after it), so a poll before
        // that finishes must not ask for another.
        await setup.refresh()
        #expect(machine.relaunches == 1, "one relaunch at a time")
    }
}

// Criterion 4: a launch that began trusted never relaunches, so a fn tap that still
// fails can't send the app round in a loop.
@MainActor
@Test func aTrustedLaunchNeverRelaunches() async {
    let machine = Machine()
    machine.write { $0.trusted = true }
    await withSetup(machine, fnOn: false, install: finishingInstall(machine)) { setup in
        for _ in 0..<3 { await setup.refresh() }
        #expect(machine.relaunches == 0, "a trusted launch has no relaunch to make")
    }
}

// Criterion 4: the model download starts once both permissions are granted, and not
// before. Each permission alone leaves the other step waiting, so nothing downloads.
@MainActor
@Test(.timeLimit(.minutes(1)))
func theModelDownloadStartsOnlyOnceBothPermissionsAreGranted() async {
    // Microphone undetermined, Accessibility not trusted, fn on, no model yet.
    let machine = Machine()
    let finish = Gate()
    let install: Install = { _, _ in
        machine.write { $0.installs += 1 }
        await finish.wait()  // holds the download open, so later polls meet it running
        machine.write { $0.modelInstalled = true }
    }
    await withSetup(machine, fnOn: true, install: install) { setup in
        let window = FakeWindow()
        setup.makeWindow = { _, _ in window }
        setup.show()
        #expect(!window.renders.isEmpty, "show() draws the setup window")

        // A due download starts inside the poll (the row goes to downloading at once), so
        // the model still missing right after it means none started.
        await setup.refresh()
        #expect(setup.facts.model == .missing, "no download while Microphone and Accessibility are both missing")

        machine.write { $0.microphone = .granted }
        await setup.refresh()
        #expect(setup.facts.model == .missing, "Microphone alone doesn't start it: Accessibility is still missing")
        #expect(machine.installs == 0)
        #expect(machine.microphoneGrants == 1, "the Microphone grant is handled once")

        machine.write { $0.trusted = true }
        await setup.refresh()
        let started = await waitUntil { machine.installs == 1 }
        #expect(started, "both granted: the download starts")

        // A poll while it runs starts no second one.
        await setup.refresh()
        finish.open()
        let installed = await waitUntil { setup.facts.model == .installed }
        #expect(installed)
        #expect(machine.installs == 1, "exactly one download")
        #expect(machine.microphoneGrants == 1)
    }
}

// The download's last steps. Progress reports hop to the main actor, so the test waits
// for each state the fake download has reached, and the fake waits for the test before
// it moves on: each state is seen, in order, whatever the machine's speed.
@MainActor
@Test(.timeLimit(.minutes(1)))
func theModelShowsPreparingBetweenTheDownloadAndTheInstall() async {
    let machine = Machine()  // everything granted and fn on; only the model is missing
    machine.write { $0.trusted = true; $0.microphone = .granted }
    let sawDownloading = Gate()
    let release = Gate()
    let install: Install = { _, progress in
        machine.write { $0.installs += 1 }
        progress(.downloading(0.5))
        await sawDownloading.wait()
        progress(.preparing)  // the download is done; CoreML prepares the model (about 25 s)
        await release.wait()
        machine.write { $0.modelInstalled = true }
    }
    await withSetup(machine, fnOn: true, install: install) { setup in
        setup.makeWindow = { _, _ in FakeWindow() }
        setup.show()

        let downloading = await waitUntil { setup.facts.model == .downloading(0.5) }
        #expect(downloading, "progress shows the download at 50%")
        sawDownloading.open()

        let preparing = await waitUntil { setup.facts.model == .preparing }
        #expect(preparing, "the model is preparing once the download is done")
        #expect(SetupCopy.row(.model, setup.facts).detail == "Preparing the model.")
        release.open()

        let installed = await waitUntil { setup.facts.model == .installed }
        #expect(installed, "the model is installed once preparing finishes")
        #expect(machine.installs == 1, "the download ran once")
    }
}

// Criterion 5, through the menu itself: with both permissions missing, the menu bar
// menu has a line for each, in order, before the start at login line.
@MainActor
@Test func theMenuNamesEveryMissingPermission() async {
    let machine = Machine()  // Microphone undetermined, Accessibility not trusted
    await withSetup(machine, fnOn: false, install: finishingInstall(machine)) { setup in
        let titles = setup.menuItems().map(\.title)
        #expect(Array(titles.prefix(2)) == ["Microphone is off: Set Up…", "fn is off: Set Up…"])
        machine.write { $0.microphone = .granted }
        await setup.refresh()
        #expect(setup.menuItems().map(\.title).first == "fn is off: Set Up…")
        #expect(!setup.menuItems().map(\.title).contains("Microphone is off: Set Up…"))
    }
}
