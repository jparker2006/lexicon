import Foundation
import Testing
@testable import AudioCapture
import LexiconDomain

// The mic lane (#186) without the mic: FakeMic, FakeEngine and TestClock through
// the real Recorder, as in LiveCaptureTests.swift.

// MARK: A late start on an abandoned lane

@Test(.timeLimit(.minutes(1)))
func aLateLookupNeverStartsThePreparedEngineOnItsAbandonedLane() async throws {
    // The deadline abandons the lane while the lookup is still stuck. When the lookup returns,
    // nothing may start the prepared engine: only a later cutOff would stop it again.
    let clock = TestClock()
    let mic = FakeMic(wedgesAtFind: [1], current: true, clock: clock)
    defer { mic.unwedge() }  // never leave a thread blocked, even when an expectation fails
    let recorder = Recorder(hardware: mic.hardware)
    var engines = mic.made.makeAsyncIterator()
    var wedgedLookups = mic.findWedged.makeAsyncIterator()

    // Lookup 0 and engine 0: the prepared engine, built while idle.
    recorder.prepare(.microphone(deviceUID: nil))
    await withCheckedContinuation { done in recorder.microphone.queue.async { done.resume() } }
    let prepared = try #require(await engines.next())
    // The abandon swaps in a fresh lane, so keep the queue the stuck start runs on.
    let stuckQueue = recorder.microphone.queue

    let stuckFile = try scratchDirectory().appending(path: "stuck.caf")
    let stuck = Task { () async -> RecorderError? in
        do throws(RecorderError) {
            let capture = try await recorder.start(.microphone(deviceUID: nil), writingTo: stuckFile)
            _ = await capture.stop(.immediately)
            return nil
        } catch {
            return error
        }
    }
    try #require(await wedgedLookups.next())

    await clock.waitForSleep(endingAt: Microphone.startLimit)
    await clock.advance(by: Microphone.startLimit)
    guard case .startTimedOut? = await stuck.value else {
        Issue.record("the stuck start should time out")
        return
    }

    // The lookup returns now, on the abandoned lane. Drain that lane so everything queued on it has run.
    mic.unwedge()
    await withCheckedContinuation { done in stuckQueue.async { done.resume() } }
    // A start here would hold the device a fresh lane may own by now.
    #expect(prepared.timesStarted == 0)
}

@Test(.timeLimit(.minutes(1)))
func aLookupReleasedBeforeTheDeadlineStartsThePreparedEngineOnceAndRecords() async throws {
    // The same stuck lookup, released inside the limit, is not abandoned: the
    // prepared engine starts once, and the start builds no second engine.
    let clock = TestClock()
    let mic = FakeMic(wedgesAtFind: [1], current: true, clock: clock)
    defer { mic.unwedge() }  // never leave a thread blocked, even when an expectation fails
    let recorder = Recorder(hardware: mic.hardware)
    var engines = mic.made.makeAsyncIterator()

    recorder.prepare(.microphone(deviceUID: nil))
    await withCheckedContinuation { done in recorder.microphone.queue.async { done.resume() } }
    let prepared = try #require(await engines.next())

    // Released once the lookup is stuck with its deadline armed, and before the clock moves.
    let release = Task {
        var wedgedLookups = mic.findWedged.makeAsyncIterator()
        _ = await wedgedLookups.next()
        await clock.waitForSleep(endingAt: Microphone.startLimit)
        mic.unwedge()
    }
    defer { release.cancel() }
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "released.caf"))
    var feed = capture.feed.makeAsyncIterator()
    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    // Counted before the stop: a stop prepares the next engine, which would be a second build.
    #expect(prepared.timesStarted == 1)
    #expect(mic.timesMade == 1)
    let take = await capture.stop(.immediately)
    await recorder.settle()
    #expect(take.clip.samples.count == FakeEngine.frames)
}

// MARK: One Allow prompt at a time

/// What these tests wait on, in the order it happens: a request asked for, or a
/// start's answer (nil once the capture recorded).
enum AllowPromptStep: Sendable {
    case asked
    case returned(RecorderError?)
}

/// Starts a capture on its own task and reports its answer. A capture that starts
/// is stopped at once: these tests only ask whether it started.
private func reportedMicStart(_ recorder: Recorder, writingTo file: URL,
                              _ report: AsyncStream<AllowPromptStep>.Continuation) {
    Task {
        do throws(RecorderError) {
            let capture = try await recorder.start(.microphone(deviceUID: nil), writingTo: file)
            _ = await capture.stop(.immediately)
            report.yield(.returned(nil))
        } catch {
            report.yield(.returned(error))
        }
    }
}

// The prompt requests and the starts' answers come through one stream, so a test
// waits on whichever happens first and never hangs on the other.

@Test(.timeLimit(.minutes(1)))
func aSecondStartWhileTheAllowPromptIsUpFailsAtOnceAndAsksNothing() async throws {
    // A second fn-down while Jake reads the prompt must not show it again or wait
    // out a second limit: it fails at once.
    let clock = TestClock()
    let mic = FakeMic(clock: clock, askingPermission: true)
    defer { mic.answerPrompt() }  // never leave a start waiting on the prompt
    let recorder = Recorder(hardware: mic.hardware)
    let (steps, report) = AsyncStream<AllowPromptStep>.makeStream()
    let asks = Task { for await _ in mic.asked { report.yield(.asked) } }
    defer { asks.cancel() }
    var answers = steps.makeAsyncIterator()

    reportedMicStart(recorder, writingTo: try scratchDirectory().appending(path: "first.caf"), report)
    guard case .asked? = await answers.next() else {
        Issue.record("the first start should ask for the Allow prompt")
        return
    }

    let before = clock.now
    reportedMicStart(recorder, writingTo: try scratchDirectory().appending(path: "second.caf"), report)
    // A start that asked again would then wait on the clock, which never moves,
    // so `.asked` is what arrives first in that case.
    guard case .returned(.startTimedOut?) = await answers.next() else {
        Issue.record("a second start while the prompt is up should fail at once, without asking again")
        return
    }
    #expect(clock.now == before)
    #expect(mic.timesAsked == 1)

    // Jake allows it, and the first start, the one that waited, records.
    mic.answerPrompt()
    _ = await answers.next()
    await recorder.settle()
}

@Test(.timeLimit(.minutes(1)))
func thePromptLimitFreesTheNextStartEvenWhenTheRequestNeverReturns() async throws {
    // The request never returns here: a prompt nobody answers never does. Its flag
    // must still clear at the limit, so the start after the limit asks again.
    let clock = TestClock()
    let mic = FakeMic(clock: clock, askingPermission: true)
    defer { mic.answerPrompt() }  // never leave a start waiting on the prompt
    let recorder = Recorder(hardware: mic.hardware)
    let (steps, report) = AsyncStream<AllowPromptStep>.makeStream()
    let asks = Task { for await _ in mic.asked { report.yield(.asked) } }
    defer { asks.cancel() }
    var answers = steps.makeAsyncIterator()

    reportedMicStart(recorder, writingTo: try scratchDirectory().appending(path: "first.caf"), report)
    guard case .asked? = await answers.next() else {
        Issue.record("the first start should ask for the Allow prompt")
        return
    }
    await clock.waitForSleep(endingAt: Microphone.promptLimit)  // the first start's wait is pending

    // Up to the limit, every further start fails at once and asks nothing.
    await clock.advance(by: Microphone.promptLimit - .seconds(1))
    reportedMicStart(recorder, writingTo: try scratchDirectory().appending(path: "during.caf"), report)
    guard case .returned(.startTimedOut?) = await answers.next() else {
        Issue.record("a start before the limit should fail at once, without asking again")
        return
    }
    #expect(mic.timesAsked == 1)

    // At the limit the first start gives up. The flag clears in that same step, so
    // the start after it is not refused.
    await clock.advance(by: .seconds(1))
    guard case .returned(.startTimedOut?) = await answers.next() else {
        Issue.record("the first start should time out at the limit")
        return
    }

    reportedMicStart(recorder, writingTo: try scratchDirectory().appending(path: "after.caf"), report)
    guard case .asked? = await answers.next() else {
        Issue.record("a start after the limit should ask the Allow prompt again")
        return
    }
    #expect(mic.timesAsked == 2)
    // Like the first start, it waits on the prompt for its own limit.
    await clock.waitForSleep(endingAt: Microphone.promptLimit * 2)

    mic.answerPrompt()
    _ = await answers.next()
    await recorder.settle()
}

@Test(.timeLimit(.minutes(1)))
func aStartAfterTheAllowPromptIsAnsweredRecords() async throws {
    // Once Jake allows the mic, the start that waited records, and a later start
    // records without asking again: MicPermission remembers the answer while
    // macOS still reports the permission undetermined.
    let clock = TestClock()
    let mic = FakeMic(clock: clock, askingPermission: true)
    defer { mic.answerPrompt() }  // never leave a start waiting on the prompt
    let recorder = Recorder(hardware: mic.hardware)
    let (steps, report) = AsyncStream<AllowPromptStep>.makeStream()
    let asks = Task { for await _ in mic.asked { report.yield(.asked) } }
    defer { asks.cancel() }
    var answers = steps.makeAsyncIterator()

    reportedMicStart(recorder, writingTo: try scratchDirectory().appending(path: "first.caf"), report)
    guard case .asked? = await answers.next() else {
        Issue.record("the first start should ask for the Allow prompt")
        return
    }
    mic.answerPrompt()
    guard case .returned(let error)? = await answers.next(), error == nil else {
        Issue.record("the start that waited on the prompt should record once Jake allows it")
        return
    }

    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "later.caf"))
    var feed = capture.feed.makeAsyncIterator()
    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    let take = await capture.stop(.immediately)
    await recorder.settle()

    #expect(take.clip.samples.count == FakeEngine.frames)
    #expect(mic.timesAsked == 1)
}

@Test(.timeLimit(.minutes(1)))
func thePromptBlockEndsExactlyAtTheLimit() async throws {
    // The block is time, not a step the first start takes on its way out: a
    // fn-down at the limit asks again even before the first start has failed.
    let clock = TestClock()
    let mic = FakeMic(clock: clock, askingPermission: true)
    defer { mic.answerPrompt() }  // never leave a start waiting on the prompt
    let recorder = Recorder(hardware: mic.hardware)
    var asked = mic.asked.makeAsyncIterator()
    let files = try (0..<2).map { try scratchDirectory().appending(path: "limit\($0).caf") }
    func press(_ file: URL) -> Task<RecorderError?, Never> {
        Task {
            do throws(RecorderError) {
                let capture = try await recorder.start(.microphone(deviceUID: nil), writingTo: file)
                _ = await capture.stop(.immediately)
                return nil
            } catch {
                return error
            }
        }
    }

    let first = press(files[0])
    _ = await asked.next()
    await clock.waitForSleep(endingAt: Microphone.promptLimit)
    await clock.advance(by: Microphone.promptLimit)
    let second = press(files[1])
    _ = await asked.next()  // a start refused here would never ask: the time limit fails the test
    mic.answerPrompt()

    #expect(await second.value == nil)
    #expect(mic.timesAsked == 2)
    _ = await first.value
    await recorder.settle()
}

// MARK: The device-rebuild loop

@Test(.timeLimit(.minutes(1)))
func theDeviceRebuildWaitsOnTheClockBetweenTries() async throws {
    // Build 0 is the first capture's engine. Build 1 stops itself at start (try 1),
    // build 2 throws (try 2), and build 3 runs and records (try 3).
    let clock = TestClock()
    let mic = FakeMic(diesAtStart: [1], failsAtMake: [2], clock: clock)
    let recorder = Recorder(hardware: mic.hardware)
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "rebuild.caf"))
    var engines = mic.made.makeAsyncIterator()
    var feed = capture.feed.makeAsyncIterator()

    // After a drain, every try that is not waiting on the clock has run. The second
    // drain also covers lane work that a drained block queued behind itself.
    func drain() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                recorder.microphone.queue.async { done.resume() }
            }
        }
    }

    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    try #require(await engines.next()).hardwareChanged()

    // Try 1 built engine 1, which is not running, so the next try waits 100 ms on the clock.
    await drain()
    try #require(mic.timesMade == 2)  // no second try before the clock moves
    let rebuilt = try #require(await engines.next())
    #expect(!rebuilt.isRunning)
    await clock.waitForSleep(endingAt: .milliseconds(100))

    await clock.advance(by: .milliseconds(99))
    await drain()
    try #require(mic.timesMade == 2)  // 1 ms to go: no try yet

    // Try 2 builds engine 2, which throws. A failed build never reaches `made`, so the
    // build count is the signal for it, and its own retry is due 100 ms after that.
    await clock.advance(by: .milliseconds(1))
    await clock.waitForSleep(endingAt: .milliseconds(200))
    try #require(mic.timesMade == 3)

    await clock.advance(by: .milliseconds(99))
    await drain()
    try #require(mic.timesMade == 3)  // 1 ms to go: no try yet

    // Try 3 builds engine 3 (the fourth build), which starts and delivers its frames.
    await clock.advance(by: .milliseconds(1))
    _ = try #require(await engines.next())
    try #require(mic.timesMade == 4)
    while heard < 2 * FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    let take = await capture.stop(.immediately)
    await recorder.settle()

    // Everything captured before the stop: engine 0's frames, then engine 3's.
    #expect(take.clip.samples.count == 2 * FakeEngine.frames)
}

@Test(.timeLimit(.minutes(1)))
func fnUpWhileARebuildWaitsKeepsWhatWasCapturedAndEndsTheWait() async throws {
    // The device keeps failing until Jake lets go: the stop ends the capture with
    // what came before, and the try still waiting is called off, not left to run.
    let clock = TestClock()
    let mic = FakeMic(diesAtStart: [1], clock: clock)
    let recorder = Recorder(hardware: mic.hardware)
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "stopped.caf"))
    var engines = mic.made.makeAsyncIterator()
    var feed = capture.feed.makeAsyncIterator()

    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    try #require(await engines.next()).hardwareChanged()
    await clock.waitForSleep(endingAt: .milliseconds(100))

    let take = await capture.stop(.immediately)
    await recorder.settle()
    await withCheckedContinuation { done in recorder.microphone.queue.async { done.resume() } }

    #expect(take.clip.samples.count == FakeEngine.frames)
    #expect(clock.sleepers == 0)
}

@Test(.timeLimit(.minutes(1)))
func aChangeFromARebuiltEngineThatNeverRanStillWaitsOnTheClock() async throws {
    // The engine a rebuild made stopped at start and then posts its own change:
    // the try already waiting covers it, so nothing runs before the clock moves.
    let clock = TestClock()
    let mic = FakeMic(diesAtStart: [1], clock: clock)
    let recorder = Recorder(hardware: mic.hardware)
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "noisy.caf"))
    var engines = mic.made.makeAsyncIterator()
    var feed = capture.feed.makeAsyncIterator()

    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    try #require(await engines.next()).hardwareChanged()
    let rebuilt = try #require(await engines.next())
    await clock.waitForSleep(endingAt: .milliseconds(100))

    rebuilt.hardwareChanged()
    for _ in 0..<2 {
        await withCheckedContinuation { done in recorder.microphone.queue.async { done.resume() } }
    }
    #expect(mic.timesMade == 2)

    await clock.advance(by: .milliseconds(100))
    while heard < 2 * FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    let take = await capture.stop(.immediately)
    await recorder.settle()
    #expect(take.clip.samples.count == 2 * FakeEngine.frames)
}

// MARK: Queued, not stuck

@Test(.timeLimit(.minutes(1)))
func aHoldQueuedBehindSlowPressesWaitsItsTurnInsteadOfFailing() async throws {
    // A run of quick presses queues engine work on the one lane. Each piece is
    // slow but finishes, so the hold behind them is queued, not stuck: the start
    // limit counts only time in which the lane finishes nothing.
    let clock = TestClock()
    let mic = FakeMic(wedgesAtStart: [0, 1], clock: clock)
    defer { mic.unwedge() }  // never leave a thread blocked, even when an expectation fails
    let recorder = Recorder(hardware: mic.hardware)
    var wedged = mic.wedged.makeAsyncIterator()
    let files = try (0..<3).map { try scratchDirectory().appending(path: "press\($0).caf") }
    func press(_ file: URL) -> Task<RecorderError?, Never> {
        Task {
            do throws(RecorderError) {
                let capture = try await recorder.start(.microphone(deviceUID: nil), writingTo: file)
                _ = await capture.stop(.immediately)
                return nil
            } catch {
                return error
            }
        }
    }

    let first = press(files[0])
    _ = await wedged.next()
    let second = press(files[1]), hold = press(files[2])
    await clock.waitForSleepers(3)

    // The first press's engine starts in 1.5 s, inside its limit; the second's start is slow too.
    await clock.advance(by: .milliseconds(1_500))
    mic.unwedgeOneStart()
    _ = await wedged.next()
    // 2 s after the hold's fn-down, but the lane finished something 0.5 s ago.
    await clock.advance(by: .milliseconds(500))
    mic.unwedgeOneStart()

    #expect(await first.value == nil)
    #expect(await second.value == nil)
    #expect(await hold.value == nil)
}
