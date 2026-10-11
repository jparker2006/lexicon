import Foundation

/// A serial executor backed by one dedicated thread running a CFRunLoop. Makes
/// `TargetApp` run there: AX calls (synchronous IPC that can block up to the
/// messaging timeout) and AXObserver run loop sources live on this thread.
///
/// `@unchecked Sendable`: its only state is the run loop, set before `init`
/// returns and never changed; CFRunLoopPerformBlock and CFRunLoopWakeUp may be
/// called from any thread.
final class RunLoopExecutor: SerialExecutor, @unchecked Sendable {
    private let runLoop: CFRunLoop

    init(name: String) {
        let started = Started()
        let thread = Thread {
            // A source with nothing to do keeps the run loop running when idle.
            var context = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            started.loop = CFRunLoopGetCurrent()
            started.ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        started.ready.wait()
        runLoop = started.loop!  // set before `ready` is signalled
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Hands the new thread's run loop back to `init`. `@unchecked`: written
    /// once on the new thread before `ready` is signalled, read after the wait.
    private final class Started: @unchecked Sendable {
        var loop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
    }
}
