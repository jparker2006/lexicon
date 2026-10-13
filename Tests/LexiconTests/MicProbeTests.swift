import Testing
@testable import AudioCapture

#if DEBUG
// #186 criterion 7: the debug probe refuses the values the harness let through.
// MicProbe.measure starts the real mic for `seconds`, so the bounds live in a pure
// `MicProbe.check` that measure calls before it makes a Recorder. Every test here
// calls only the check, except the last one, which is safe only because the check
// throws first.

/// Whether a probe refusal is the one the criterion names. RecorderError is not
/// Equatable, so the case is matched here rather than compared with #expect(throws: value).
private func isEngineFailed(_ error: RecorderError?) -> Bool {
    if case .engineFailed? = error { return true }
    return false
}

@Test(.timeLimit(.minutes(1)))
func aProbeOutsideTheSecondsRangeIsRefused() {
    // Zero is refused as well: the harness only lets through more than 0 seconds, and the probe must match it.
    let zero = #expect(throws: RecorderError.self) { try MicProbe.check(seconds: 0, preparedIdle: nil) }
    #expect(isEngineFailed(zero))

    let negative = #expect(throws: RecorderError.self) { try MicProbe.check(seconds: -1, preparedIdle: nil) }
    #expect(isEngineFailed(negative))

    let million = #expect(throws: RecorderError.self) { try MicProbe.check(seconds: 1_000_000, preparedIdle: nil) }
    #expect(isEngineFailed(million))

    // Just past the 120 s cap; 120 itself is allowed, in the next test.
    let justOver = #expect(throws: RecorderError.self) { try MicProbe.check(seconds: 120.000001, preparedIdle: nil) }
    #expect(isEngineFailed(justOver))
}

@Test(.timeLimit(.minutes(1)))
func aProbeInsideTheLimitsIsAllowed() throws {
    try MicProbe.check(seconds: 120, preparedIdle: nil)
    try MicProbe.check(seconds: 0.5, preparedIdle: nil)
    try MicProbe.check(seconds: 5, preparedIdle: nil)
    // A prepared idle of exactly 30 s is the most the probe waits before fn-down.
    try MicProbe.check(seconds: 5, preparedIdle: 30)
}

@Test(.timeLimit(.minutes(1)))
func aProbeWithAPreparedIdleOver30SecondsIsRefused() {
    let idle = #expect(throws: RecorderError.self) { try MicProbe.check(seconds: 5, preparedIdle: 31) }
    #expect(isEngineFailed(idle))
}

// This runs the real measure, so it is only safe once `MicProbe.check` exists: the
// fixed measure throws before it makes a Recorder. Until then this file does not
// compile, so nothing here can open the real mic on today's code. If the check ever
// moved after the Recorder, this test would open the real mic and sleep for days
// (the time limit fails the test but cannot stop the mic).
@Test(.timeLimit(.minutes(1)))
func aProbeAskedForMillionsOfSecondsIsRefusedBeforeTheMicStarts() async throws {
    let folder = try scratchDirectory()
    let refused = await #expect(throws: RecorderError.self) {
        _ = try await MicProbe.measure(seconds: 1_000_000, preparedIdle: nil, deviceChange: false,
                                       deviceUID: nil, folder: folder)
    }
    #expect(isEngineFailed(refused))
}
#endif
