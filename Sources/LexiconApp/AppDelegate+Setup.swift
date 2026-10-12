import AppKit
import os
import LexiconDomain
import KeyInput
import LexiconCore
import LexiconUI
import LocalParakeet

// First-run setup and start at login, one run loop turn after the status item.

extension AppDelegate {
    func startSetup(statusItem: StatusItemController, preferences: PreferencesStore, paths: AppPaths,
                    bundleID: String) {
        let log = Logger(subsystem: bundleID, category: "launch")
        // One run loop turn after the status item exists: the closest in-process mark
        // for the icon being on screen (the window server composites it just after).
        let ms = { (seconds: Double?) in seconds.map { Int(($0 * 1000).rounded()) } ?? -1 }
        let icon = ms(LaunchClock.sinceProcessStart()), main = ms(LaunchClock.mainStarted)
        // After the mark: setup's first reads (Accessibility trust and the Microphone
        // answer, 20 to 50 ms cold, the login item, the model folder) need not hold the icon.
        let setup = Setup(statusItem: statusItem, preferences: preferences,
                          services: Self.setupServices(paths: paths, system: system),
                          relaunched: CommandLine.arguments.contains(Setup.relaunchArgument),
                          registersAtLogin: bundleID == AppPaths.dailyBundleID)
        self.setup = setup
        setup.start()
        if let system { Task { await setup.follow(await system.conductor.events()) } }
        log.notice("""
            status item up \(icon, privacy: .public) ms after process start (main at \(main, privacy: .public) ms); \
            \(setup.permissionsSummary, privacy: .public)
            """)
        // After the mark, so the icon never waits for it; fn runs off the main thread.
        DispatchQueue.main.async { [weak self] in _ = self?.history?.warmUp() }
    }

    /// What setup needs from modules only the shell imports: the fn tap and the
    /// globe key (KeyInput), the model (LocalParakeet), the mic (the system's recorder).
    static func setupServices(paths: AppPaths, system: LexiconSystem?) -> Setup.Services {
        Setup.Services(
            fnOn: system != nil && system?.fnOff == nil,
            globeKeyOK: { !GlobeKey.hasSystemAction },
            modelInstalled: { ParakeetTranscriber.isInstalled(paths: paths) },
            installModel: { access, progress in
                try await ParakeetTranscriber.install(paths: paths, access: access, progress: progress)
            },
            modelInstalledNow: { await system?.loadModel() },
            microphoneGranted: {
                guard let system else { return }
                system.recorder.prepare(.microphone(deviceUID: system.preferences.snapshot().microphoneUID))
            })
    }
}
