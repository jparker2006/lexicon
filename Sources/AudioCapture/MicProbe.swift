#if DEBUG
public import Foundation
public import LexiconDomain

/// The live-app lane's measurement of the mic (#52): one real capture from a
/// fresh Recorder, reported as numbers. Debug builds only: the dev app's test
/// hook runs it, inside the app, because only the app holds the Microphone grant.
public enum MicProbe {
    /// Records `seconds` from the mic into a scratch file in `folder`, then
    /// stops as at fn-up. `preparedIdle`: prepare first, as at launch, and
    /// wait this long before fn-down; nil builds the engine on fn-down.
    /// `deviceChange`: halfway, the engine stops itself and posts a
    /// configuration change, as when hardware changes.
    public static func measure(seconds: Double, preparedIdle: Double?, deviceChange: Bool, deviceUID: String?,
                               folder: URL) async throws(RecorderError) -> MicMeasurement {
        try check(seconds: seconds, preparedIdle: preparedIdle)
        let recorder = Recorder()
        let input = AudioInput.microphone(deviceUID: deviceUID)
        if let preparedIdle {
            recorder.prepare(input)
            await withCheckedContinuation { done in recorder.microphone.queue.async { done.resume() } }
            try? await Task.sleep(for: .seconds(preparedIdle))
        }
        let file = folder.appending(path: "mic-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let device = InputDevices.find(uid: deviceUID)

        // As the Conductor does from fn-down: App Nap must not slow the start being measured.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "mic probe")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let capture = try await recorder.start(input, writingTo: file, since: .now())
        let core = capture.core
        let warm = (core.source as? MicSource)?.warm ?? false
        try? await Task.sleep(for: .seconds(seconds / 2))
        let inUseWhileRecording = device.map(InputDevices.isRunningSomewhere) ?? false
        if deviceChange { recorder.microphone.simulateDeviceChange() }
        try? await Task.sleep(for: .seconds(seconds / 2))

        let released = HostTime.now()
        let take = await capture.stop(.released(at: released))
        let stopped = HostTime.now().duration(since: released)
        await recorder.settle()
        try? await Task.sleep(for: .milliseconds(500))
        // Any input at all, not just the pinned one: the engine also makes a private aggregate device.
        let inUseAfterStop = InputDevices.all().contains(where: InputDevices.isRunningSomewhere)
        let saved = try? CAFFile.read(file)

        return MicMeasurement(
            device: take.summary.deviceName, engine: warm ? "prepared" : "cold",
            startGapMs: take.summary.startGap?.ms, capturedMs: take.summary.duration.ms,
            levelDBFS: dBFS(take.clip.samples[...]),
            lastBlocksDBFS: stride(from: max(0, take.clip.samples.count - 4_800), to: take.clip.samples.count, by: 160).map {
                Int(dBFS(take.clip.samples[$0..<min($0 + 160, take.clip.samples.count)]).rounded())
            },
            tailMs: core.tailLength?.ms ?? -1, stopMs: stopped.ms, fileMs: saved?.duration.ms,
            fileMatchesClip: saved?.samples == take.clip.samples, storage: take.summary.storage.rawValue,
            deviceChangeGapsMs: take.summary.gaps.map(\.ms),
            micInUseWhileRecording: inUseWhileRecording, micInUseAfterStop: inUseAfterStop,
            inputs: InputDevices.all().map { "\(InputDevices.name($0) ?? "?") [\(InputDevices.uid($0) ?? "?")]" })
    }

    /// A probe holds the real mic for its whole length, so a typo can't keep it for days.
    /// The closed ranges also refuse NaN, which `Duration.seconds` would trap on.
    static func check(seconds: Double, preparedIdle: Double?) throws(RecorderError) {
        guard seconds > 0, seconds <= 120 else { throw .engineFailed("probe seconds \(seconds) not in (0, 120]") }
        guard (0...30).contains(preparedIdle ?? 0) else {
            throw .engineFailed("probe prepared idle \(preparedIdle ?? 0) not in [0, 30]")
        }
    }

    private static func dBFS(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return -120 }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return max(-120, 20 * log10(energy.squareRoot() / 32_768))
    }
}
#endif
