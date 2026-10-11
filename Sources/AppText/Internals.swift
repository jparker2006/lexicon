import Foundation

/// A serial executor backed by one dedicated thread running a CFRunLoop. Makes
/// `TargetApp` run there: AX calls (synchronous IPC that can block up to the
/// messaging timeout) and AXObserver run loop sources live on this thread.
final class RunLoopExecutor: SerialExecutor, @unchecked Sendable {
    init(name: String) { fatalError("not implemented") }

    func enqueue(_ job: consuming ExecutorJob) {
        // TODO: let unowned = UnownedJob(job); CFRunLoopPerformBlock(runLoop, commonModes) {
        //   unowned.runSynchronously(on: self.asUnownedSerialExecutor()) }; CFRunLoopWakeUp(runLoop)
        fatalError("not implemented")
    }
}

/// Handy-style clipboard restore (#7). Lives with the paste because it is the
/// same decision: we own the pasteboard from write until restore. Pasteboard
/// writes and the promise provider run on the main actor (AppKit pasteboard
/// owner callbacks arrive on the main run loop; verify in M0).
final class PasteboardRestorer: @unchecked Sendable {
    let quietPeriod: Duration = .milliseconds(200)
    let cap: Duration = .seconds(8)
}
