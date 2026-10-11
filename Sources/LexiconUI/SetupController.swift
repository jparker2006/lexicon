public import AppKit
import AVFAudio
import os
public import LexiconDomain
public import LexiconCore

/// First-run setup, the warning dot and start at login (#57). Reads the two
/// permissions, the model and the globe key into `SetupFacts`, shows the setup
/// window when it should open (first run, or the relaunch after the
/// Accessibility grant), points the menu bar icon's dot at a missing permission
/// and relaunches the app once Accessibility is granted.
///
/// Polls: macOS announces neither grant to a running app. Once a second while
/// the window is open, every five seconds otherwise.
@MainActor
public final class Setup: NSObject {
    /// What only the app shell can reach: the fn tap, the globe key setting
    /// (KeyInput), the model files and their install (LocalParakeet), the mic.
    public struct Services {
        /// The fn tap started at launch. It can't start later in the same process.
        public var fnOn: Bool
        public var globeKeyOK: @MainActor () -> Bool
        public var modelInstalled: @MainActor () -> Bool
        /// Downloads and compiles the model under `access`, reporting 0...1.
        public var installModel: @Sendable (CloudAccess, @escaping @Sendable (Double) -> Void) async throws -> Void
        /// After the install: load it now, so the first fn press doesn't wait.
        public var modelInstalledNow: @Sendable () async -> Void
        /// Microphone granted while running: prepare the mic, so fn-down only starts it.
        public var microphoneGranted: @MainActor () -> Void

        public init(fnOn: Bool, globeKeyOK: @escaping @MainActor () -> Bool, modelInstalled: @escaping @MainActor () -> Bool,
                    installModel: @escaping @Sendable (CloudAccess, @escaping @Sendable (Double) -> Void) async throws -> Void,
                    modelInstalledNow: @escaping @Sendable () async -> Void,
                    microphoneGranted: @escaping @MainActor () -> Void) {
            self.fnOn = fnOn
            self.globeKeyOK = globeKeyOK
            self.modelInstalled = modelInstalled
            self.installModel = installModel
            self.modelInstalledNow = modelInstalledNow
            self.microphoneGranted = microphoneGranted
        }
    }

    /// Passed to the relaunched copy, so setup carries on where it was.
    public static let relaunchArgument = "--continue-setup"

    let statusItem: StatusItemController
    let preferences: PreferencesStore
    let services: Services
    let relaunched: Bool
    /// Only the daily copy registers itself at login unasked. A dev build that
    /// did would start beside it after every login, two apps on one fn key.
    let registersAtLogin: Bool
    let relaunchRule: RelaunchRule
    private(set) var facts: SetupFacts
    private var window: SetupWindowController?
    private var timer: Timer?
    private var downloading: Task<Void, Never>?
    private var relaunching = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lexicon", category: "setup")

    public init(statusItem: StatusItemController, preferences: PreferencesStore, services: Services,
                relaunched: Bool, registersAtLogin: Bool) {
        self.statusItem = statusItem
        self.preferences = preferences
        self.services = services
        self.relaunched = relaunched
        self.registersAtLogin = registersAtLogin
        let trusted = AXIsProcessTrusted()
        relaunchRule = RelaunchRule(trustedAtLaunch: trusted, fnOn: services.fnOn)
        facts = SetupFacts(microphone: Self.microphone, accessibility: trusted, fnOn: services.fnOn,
                           trustedAtLaunch: trusted, model: services.modelInstalled() ? .installed : .missing,
                           globeKeyOK: services.globeKeyOK(), triedFn: false)
        super.init()
    }

    /// "granted", "denied" or "undetermined", for the launch log and the test hooks' status.
    public static var microphoneName: String {
        switch microphone {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        }
    }

    /// For the launch log line, read by the grant check in the PR evidence.
    public static var permissionsSummary: String { "accessibility=\(AXIsProcessTrusted()) microphone=\(microphoneName)" }

    public func start() {
        applyLoginItemAtLaunch()
        statusItem.onWarningClick = { [weak self] step in self?.show(step) }
        statusItem.warning = facts.warning
        if facts.opensAtLaunch(relaunched: relaunched) { show(facts.current) }
        schedulePoll()
    }

    /// Opens the window at `step` (the dot's step, or wherever setup is).
    public func show(_ step: SetupStep? = nil) {
        if window == nil {
            window = SetupWindowController(actions: actions(), onClose: { [weak self] in
                self?.window = nil
                self?.schedulePoll()
            })
        }
        facts.globeKeyOK = services.globeKeyOK()
        // Opening setup again is the retry for a download that stopped while it was closed.
        if facts.model == .failed { facts.model = .missing }
        window?.render(facts)
        window?.focus(step ?? facts.current)
        startDownloadIfDue()
        schedulePoll()
    }

    /// The menu bar menu's setup lines: the missing permission (also the dot's
    /// click), unfinished setup, start at login, and the globe key while it has
    /// a system action (read each time the menu opens).
    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let step = facts.warning ?? (facts.isDone(.model) ? nil : SetupStep.model) {
            let item = NSMenuItem(title: SetupCopy.warningMenuTitle(step), action: #selector(openFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = step.rawValue
            items.append(item)
        }
        let login = LoginItem.status
        let startAtLogin = NSMenuItem(title: login == .requiresApproval ? "Start at Login (turned off in System Settings)…"
                                      : "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLogin.target = self
        startAtLogin.state = login == .enabled ? .on : .off
        items.append(startAtLogin)
        if !services.globeKeyOK() {
            let globe = NSMenuItem(title: "Set “Press globe key to” to Do Nothing…", action: #selector(openKeyboardSettings),
                                   keyEquivalent: "")
            globe.target = self
            items.append(globe)
        }
        return items
    }

    // MARK: - Reading the system

    private static var microphone: MicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    private func poll() {
        var next = facts
        next.microphone = Self.microphone
        next.accessibility = AXIsProcessTrusted()
        if window != nil { next.globeKeyOK = services.globeKeyOK() }
        // Private mode turned off since the download was refused: try again.
        if next.model == .privateMode, preferences.snapshot().privacy == .standard { next.model = .missing }
        update(next)
        if relaunchRule.shouldRelaunch(trustedNow: next.accessibility) { relaunch() }
    }

    private func update(_ next: SetupFacts) {
        guard next != facts else { return }
        if next.microphone == .granted, facts.microphone != .granted { services.microphoneGranted() }
        facts = next
        statusItem.warning = facts.warning
        window?.render(facts)
        startDownloadIfDue()
    }

    private func schedulePoll() {
        let interval: TimeInterval = window != nil ? 1 : 5
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Steps

    private func actions() -> SetupWindowActions {
        SetupWindowActions(
            allowMicrophone: { [weak self] in self?.allowMicrophone() },
            openAccessibility: { [weak self] in self?.openAccessibility() },
            restart: { [weak self] in self?.relaunch() },
            downloadModel: { [weak self] in self?.downloadModel() },
            openKeyboardSettings: { [weak self] in self?.openKeyboardSettings() },
            triedFn: { [weak self] in
                guard let self else { return }
                var next = facts
                next.triedFn = true
                update(next)
            })
    }

    /// The macOS prompt the first time; after a denial only System Settings can change it.
    private func allowMicrophone() {
        guard facts.microphone == .undetermined else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }
        NSApp.activate()
        AVAudioApplication.requestRecordPermission { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    /// The prompt adds Lexicon to the Accessibility list (switched off), so
    /// the pane opened next shows it; Jake switches it on and the poll relaunches.
    private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    /// Starts by itself once the model is the step to do and the window shows
    /// it: after the permissions, so the Accessibility relaunch can't cut it off.
    private func startDownloadIfDue() {
        guard window != nil, facts.current == .model, facts.model == .missing else { return }
        downloadModel()
    }

    private func downloadModel() {
        guard downloading == nil, facts.model != .installed else { return }
        setModel(.downloading(0))
        let install = services.installModel, installed = services.modelInstalledNow
        // Whole percents only: FluidAudio reports far more often than the bar can show.
        let report: @Sendable (Double) -> Void = { fraction in
            // The nudge keeps 0.57 from reading as 56 (0.57 * 100 is 56.99999999999999).
            let percent = (fraction * 100 + 1e-9).rounded(.down) / 100
            Task { @MainActor in self.downloaded(percent) }
        }
        // Setup lives as long as the app, so holding it here costs nothing.
        downloading = Task {
            let model: ModelState
            do {
                try await preferences.downloading { access in try await install(access, report) }
                await installed()
                model = .installed
            } catch is CloudAccessRevoked where services.modelInstalled() {
                // The last byte landed as Private mode came on: the model is here, nothing more will download.
                await installed()
                model = .installed
            } catch is CloudAccessRevoked {
                model = .privateMode
            } catch {
                log.error("model download failed: \(String(describing: error), privacy: .private)")
                model = .failed
            }
            downloading = nil
            setModel(model)
        }
    }

    private func downloaded(_ percent: Double) {
        guard case .downloading(let shown) = facts.model, percent > shown else { return }
        setModel(.downloading(percent))
    }

    private func setModel(_ model: ModelState) {
        var next = facts
        next.model = model
        update(next)
    }

    // MARK: - Relaunch

    /// The tap can only start in a fresh process, so this one quits and a small
    /// shell waits for it to be gone, then opens the app again: one copy at a
    /// time, so the new one's crash recovery never sees this one's rows as
    /// abandoned. `open` goes through LaunchServices, so launchd is the new
    /// copy's parent and the launch guard lets it run. The arguments carry over
    /// (test hooks, mic), plus `relaunchArgument`. Quitting waits for any
    /// Dictation in flight (`applicationShouldTerminate`); the shell gives up
    /// after 60 s, and `open` then just brings the old copy forward.
    private func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        let arguments = CommandLine.arguments.dropFirst().filter { $0 != Self.relaunchArgument } + [Self.relaunchArgument]
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", """
            pid=$1; app=$2; shift 2; i=0
            while kill -0 "$pid" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
            exec /usr/bin/open "$app" --args "$@"
            """, "relaunch", String(getpid()), Bundle.main.bundlePath] + arguments
        do {
            try waiter.run()
            log.notice("relaunching to turn on fn")
            NSApp.terminate(nil)
        } catch {
            // Restart stays offered: Jake can quit and reopen by hand.
            log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Start at login

    private func applyLoginItemAtLaunch() {
        guard let action = LoginItem.launchAction(wanted: preferences.snapshot().startAtLogin, status: LoginItem.status),
              action != .register || registersAtLogin else { return }
        perform(action)
    }

    @objc private func toggleStartAtLogin() {
        let action = LoginItem.toggleAction(status: LoginItem.status)
        switch action {
        case .register, .openSystemSettings: preferences.update { $0.startAtLogin = true }
        case .unregister: preferences.update { $0.startAtLogin = false }
        }
        perform(action)
    }

    private func perform(_ action: LoginItem.Action) {
        do {
            try LoginItem.perform(action)
            log.notice("start at login: \(String(describing: action), privacy: .public), now \(String(describing: LoginItem.status), privacy: .public)")
        } catch {
            log.error("start at login \(String(describing: action), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func openFromMenu(_ item: NSMenuItem) {
        show(SetupStep(rawValue: item.tag))
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
