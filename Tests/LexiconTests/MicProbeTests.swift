import Testing
@testable import AudioCapture

#if DEBUG
// #186 criterion 7: the debug probe refuses the values the harness let through.
// MicProbe.measure starts the real mic for `seconds`, so the bounds live in a pure
// `MicProbe.check` that measure calls before it makes a Recorder. Only the check is
// called here: a test that called measure would open the mic if the check ever moved.

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

#endif
