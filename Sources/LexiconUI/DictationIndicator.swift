public import AppKit
public import LexiconDomain
public import AudioCapture
public import LexiconCore

/// What Jake sees and hears of a Dictation: the recording pill, the menu bar
/// icon's state and the sounds. Its state comes from the Conductor's events
/// (`follow`), through `IndicatorFollower`.
@MainActor
public final class DictationIndicator {
    let statusItem: StatusItemController
    let preferences: PreferencesStore
    let pill = RecordingPill()
    let sounds = Sounds()
    private var follower = IndicatorFollower()
    private var state: IndicatorState = .hidden
    /// The mouth step last drawn in the menu bar, so the icon is redrawn only when it changes.
    private var mouthStep = 0
    private var hideTimer: Timer?

    public init(statusItem: StatusItemController, preferences: PreferencesStore) {
        self.statusItem = statusItem
        self.preferences = preferences
    }

    /// Runs until `events` ends.
    public func follow(_ events: AsyncStream<ConductorEvent>, levels: AsyncStream<AudioLevel>) async {
        let meter = Task { for await level in levels { setLevel(level) } }
        for await event in events { handle(event) }
        meter.cancel()
    }

    public func handle(_ event: ConductorEvent) {
        // fn-down: the start sound may come once the hold is confirmed.
        if case .started = event { sounds.warm() }
        let before = follower.state
        let cue = follower.apply(event)
        if let cue { play(cue) }
        // A sound means news, so show it again even when it reads the same (a second "Nothing to paste yet").
        if follower.state != before || cue != nil { show(follower.state) }
    }

    /// Also the test hooks' way in, with a level for the recording states.
    public func show(_ state: IndicatorState, level: Float = 0) {
        hideTimer?.invalidate()
        hideTimer = nil
        self.state = state
        mouthStep = 0
        pill.show(state)
        statusItem.render(state)
        switch state {
        case .recording, .finishing: sounds.setActive(true)
        case .hidden, .landed, .pasteLast, .error: sounds.setActive(false)
        }
        // How long each passing state stays. Landed is gone by about 0.45 s: 0.15 s, then a 0.3 s fade.
        switch state {
        case .landed: hide(after: 0.15, fade: 0.3)
        case .pasteLast: hide(after: 4.5, fade: 0.2)
        case .error: hide(after: 2.5, fade: 0.2)
        case .hidden, .recording, .finishing: break
        }
        if level > 0 { show(level: level) }
    }

    public func setLevel(_ level: AudioLevel) { show(level: Self.shown(level)) }

    private func show(level shown: Float) {
        guard case .recording = state else { return }
        pill.setLevel(shown)
        // Four mouth steps are enough to read as talking, and redraw the menu bar at most a few times a second.
        let step = Int((shown * 4).rounded())
        if step != mouthStep {
            mouthStep = step
            statusItem.render(state, open: CGFloat(step) / 4)
        }
    }

    /// Test hooks: plays `cue` and waits until its first sample reaches the output.
    /// nil when Sounds is off, or the sound never played within a second.
    public func playAndMeasure(_ cue: SoundCue) async -> Duration? {
        guard preferences.snapshot().soundsOn else { return nil }
        sounds.play(cue)
        for _ in 0..<200 {
            if let latency = sounds.lastLatency { return latency }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// The "Sounds" line for the menu bar menu, with a check while on.
    public func soundsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sounds", action: #selector(SoundsToggle.toggle), keyEquivalent: "")
        item.target = toggle
        item.state = preferences.snapshot().soundsOn ? .on : .off
        return item
    }

    private lazy var toggle = SoundsToggle(preferences: preferences)

    private func play(_ cue: SoundCue) {
        if preferences.snapshot().soundsOn { sounds.play(cue) }
    }

    private func hide(after delay: TimeInterval, fade: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                self.state = .hidden
                self.statusItem.render(.hidden)
                self.pill.hide(fade: fade)
            }
        }
    }

    /// RMS to 0...1 on a dB scale: -50 dBFS (a quiet room) shows nothing, -10 dBFS (loud speech) fills the bars.
    static func shown(_ level: AudioLevel) -> Float {
        guard level.rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level.rms) + 50) / 40))
    }
}

@MainActor
private final class SoundsToggle: NSObject {
    let preferences: PreferencesStore
    init(preferences: PreferencesStore) { self.preferences = preferences }

    @objc func toggle() { preferences.update { $0.soundsOn.toggle() } }
}
