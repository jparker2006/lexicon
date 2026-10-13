import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import AudioCapture
import History
import LexiconDomain

// The audio file exists when `Recorder.start` returns, and a second start on one
// file never erases the first (#181).

// MARK: The file exists at start (criterion 1)

// The audio file exists on disk when `Recorder.start` returns,
// before any drain. The shared writer queue is held inside the first capture's
// close, so a create queued behind it cannot have run yet. File input, realtime
// pace: no mic, keys or network.

@Test(.timeLimit(.minutes(1))) func theAudioFileExistsWhenStartReturnsEvenWhileTheWriterQueueIsBusy() async throws {
    let dir = try scratchDirectory()
    // 0.5 s: under the 2 s ring, so the reader never waits on the writer queue.
    let source = syntheticSamples(count: 8_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let aURL = dir.appending(path: "audio/a.caf")
    let bURL = dir.appending(path: "audio/b.caf")

    var policy = FlushPolicy()
    // Nothing drains: the writer queue does only what the test starts.
    policy.drainEvery = .seconds(3600)
    policy.fullSyncEvery = .seconds(3600)
    // The free-space floor is off, so the file is created whatever this Mac's disk holds.
    policy.minimumFreeBytes = 0
    let (closeEntered, enteredSignal) = AsyncStream<Void>.makeStream()
    let hold = WriterQueueHold(entered: enteredSignal)
    policy.files.close = { [hold] file in hold.closeFile(file) }
    // A failed expectation below must never leave the writer queue blocked.
    defer { hold.open() }

    let recorder = Recorder(policy: policy)
    let a = try await recorder.start(.file(wav, pace: .realtime), writingTo: aURL)
    _ = await a.stop(.immediately)
    // The writer queue is now inside A's close, which the hold keeps until the test opens it.
    _ = await closeEntered.first { _ in true }

    let b = try await recorder.start(.file(wav, pace: .realtime), writingTo: bURL)
    // A create queued on the writer queue would still be behind the blocked close.
    #expect(FileManager.default.fileExists(atPath: bURL.path))

    hold.open()
    let ended = try #require(await b.signals.inputEnded())
    let take = await b.stop(.released(at: ended))
    await recorder.settle()

    #expect(take.summary.storage == .onDisk)
    #expect(take.clip.samples == source)
    #expect(try CAFFile.read(bURL).samples == take.clip.samples)  // the file made early is the one written
}

/// Holds the writer queue inside the first file close. The first call tells the
/// test it has entered, then blocks until `open`; every later call closes at once.
private final class WriterQueueHold: Sendable {
    private let calls = Mutex(0)
    private let entered: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)

    init(entered: AsyncStream<Void>.Continuation) {
        self.entered = entered
    }

    func closeFile(_ file: AudioFileID) -> OSStatus {
        let first = calls.withLock { count -> Bool in
            count += 1
            return count == 1
        }
        if first {
            entered.yield(())
            gate.wait()  // timing-ok: the test opens the gate, so the queue holds exactly as long as the test needs
        }
        return AudioFileClose(file)
    }

    /// Safe to call twice: the second signal only leaves the semaphore at one.
    func open() {
        gate.signal()
    }
}

// MARK: A second start never erases the first (criterion 2)

// Two captures on one file: the second must not erase the first file.
@Test(.timeLimit(.minutes(1))) func aSecondCaptureOnOneFileLeavesTheFirstFileAlone() async throws {
    let first = syntheticSamples(count: 16_000)
    let second = syntheticSamples(count: 8_000)
    let firstWAV = try writeWAV(first, rate: 16_000, in: try scratchDirectory())
    let secondWAV = try writeWAV(second, rate: 16_000, in: try scratchDirectory())
    let caf = try scratchDirectory().appending(path: "audio/same.caf")

    let recorder = Recorder()
    let one = try await recorder.start(.file(firstWAV, pace: .asFastAsPossible), writingTo: caf)
    let oneEnded = try #require(await one.signals.inputEnded())
    let oneTake = await one.stop(.released(at: oneEnded))
    await recorder.settle()
    #expect(oneTake.summary.storage == .onDisk)
    let before = try Data(contentsOf: caf)

    let two = try await recorder.start(.file(secondWAV, pace: .asFastAsPossible), writingTo: caf)
    let problems = two.signals.problems
    let twoEnded = try #require(await two.signals.inputEnded())
    let twoTake = await two.stop(.released(at: twoEnded))
    await recorder.settle()

    #expect(try Data(contentsOf: caf) == before)
    #expect(twoTake.clip.samples == second)
    #expect(twoTake.summary.storage == .ramOnly)
    #expect(await problems.first { _ in true } == .diskTrouble)
}

// #181 criteria 3 and 4: where a Dictation's audio file is when its capture starts.
// File input and throwaway folders: no mic, keys or network.

// Criterion 3, a guard: a folder that cannot be written sends the take to RAM and
// reports it, and the start still returns. Same fixture as
// whenTheFileCannotBeWrittenTheAudioStaysInRAM, with problems collected after stop.
@Test(.timeLimit(.minutes(1)))
func aCaptureOnAFolderThatCannotBeWrittenStartsAndStaysInRAM() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let blocker = dir.appending(path: "audio")
    try Data().write(to: blocker)  // a plain file where the audio folder should be

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: blocker.appending(path: "x.caf"))
    let problems = capture.signals.problems
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    // The stream finishes at stop and keeps what it reported, so collect it now.
    var reported: [CaptureProblem] = []
    for await problem in problems { reported.append(problem) }

    #expect(take.clip.samples == source)
    #expect(take.summary.storage == .ramOnly)
    #expect(reported.contains(.diskTrouble))
}

// Criterion 4, a guard: a capture dropped at once, with no stop, never leaves an
// audio file that no History row owns. Launch recovery either adopts the file (a
// row exists for its id) or the file is gone, whenever the file was created.
@Test(.timeLimit(.minutes(1)))
func aCaptureDroppedAtOnceNeverLeavesAFileWithNoHistoryRow() async throws {
    let paths = AppPaths.temporary()
    // A store makes audio/ and names the file for this id; the capture writes into it.
    let id = DictationID()
    let audio = try HistoryStore(paths: paths).audioURL(for: id)
    let wav = try writeWAV(longSamples(), rate: 16_000, in: try scratchDirectory())

    let recorder = Recorder()
    do {
        let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: audio)
        _ = consume capture  // dropped at once: the drop stops the capture and keeps its audio
    }
    // The drop queues its close on the writer queue, so the file is closed once settle returns.
    await recorder.settle()

    // Recovery adopts only a file created before the store opened, to the millisecond,
    // so the store opens once the clock has passed a millisecond read after the file was made, as a relaunch does.
    let closed = (Date().timeIntervalSince1970 * 1_000).rounded()
    await until { (Date().timeIntervalSince1970 * 1_000).rounded() > closed }
    let store = try HistoryStore(paths: paths)
    _ = await store.recover()
    await store.flush()

    let fileRemains = FileManager.default.fileExists(atPath: audio.path(percentEncoded: false))
    let row = await store.dictation(id)
    #expect(!fileRemains || row != nil, "a file with no History row after recovery")
}
