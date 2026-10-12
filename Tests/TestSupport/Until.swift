/// Returns once `condition` holds, checking every 5 ms, or once the task is
/// cancelled. Only for what nothing signals, such as bytes another process
/// writes to disk; wait on the signal wherever there is one. It never gives
/// up, so the test's time limit is its hang guard, and a slow Mac only polls longer.
public func until(_ condition: () async -> Bool) async {
    while !(await condition()), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(5))  // timing-ok: a poll interval; it decides nothing
    }
}
