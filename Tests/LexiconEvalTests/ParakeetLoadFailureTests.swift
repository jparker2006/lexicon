import Foundation
import Synchronization
import Testing
@testable import LocalParakeet
import LexiconDomain

// A model that fails to load fails its Dictation once, not once per window (#339).
// A clip's windows are decoded one by one, and a long Dictation's first windows are
// decoded while Jake is still talking. Without a memo of the failure, one broken load
// would be retried for every window before fn-up, each try a full read of the weights.
// A new Dictation tries the load again, since the model may have been installed or
// fixed since.

/// What the injected loader throws. `attempt` numbers the load that threw it, so a
/// test can tell the first load's error from a later one's.
private struct LoadFailure: Error, Equatable {
    let attempt: Int
}

/// A model folder that passes `ParakeetTranscriber.isComplete`: every required file
/// whole, and each `.mlmodelc` a folder holding its `coremldata.bin`. The files are
/// empty because the loader is injected and never reads them.
private func wholeModelFolder() throws -> URL {
    let folder = try scratchDirectory()
    for name in ParakeetTranscriber.requiredFiles {
        let file = folder.appending(path: name)
        if name.hasSuffix(".mlmodelc") {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            try Data().write(to: file.appending(path: "coremldata.bin"))
        } else {
            try Data().write(to: file)
        }
    }
    return folder
}

/// The error `finish` throws, or nil when it returns its text.
private func errorThrown(by finish: () async throws -> String) async -> (any Error)? {
    do {
        _ = try await finish()
        return nil
    } catch {
        return error
    }
}

/// Hands `clip` to `append` in three chunks, as the microphone delivers audio before fn-up.
private func capture(_ clip: AudioClip, _ append: ([Int16]) -> Void) {
    let chunk = clip.samples.count / 3 + 1
    for start in stride(from: 0, to: clip.samples.count, by: chunk) {
        append(Array(clip.samples[start..<min(start + chunk, clip.samples.count)]))
    }
}

@Test(.timeLimit(.minutes(1)))
func aFailedLoadIsAttemptedOncePerDictationNotOncePerWindow() async throws {
    let folder = try wholeModelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let attempts = Mutex(0)
    let transcriber = ParakeetTranscriber(folder: folder, load: { _ in
        let attempt = attempts.withLock { count -> Int in
            count += 1
            return count
        }
        throw LoadFailure(attempt: attempt)
    })

    // The grid, not a constant, sets how many windows a clip has, so this clip is three
    // windows whatever the grid is. The windows are then the ones a Dictation decodes.
    let grid = WindowDecoder.grid
    let total = grid.window + 2 * grid.stride
    #expect(grid.starts(total: total).count == 3)
    let clip = AudioClip(samples: [Int16](repeating: 0, count: total))

    // First Dictation: its windows are decoded as they are captured, then fn-up decodes
    // the ones that failed. Every window fails with the first load's error, and the
    // load ran once.
    let first = transcriber.session(terms: [], priority: .live)
    capture(clip) { first.append($0) }
    let firstError = await errorThrown { try await first.finish(clip) }
    let firstLoad = firstError as? LoadFailure
    #expect(firstLoad == LoadFailure(attempt: 1))
    let firstAttempts = attempts.withLock { count in count }
    #expect(firstAttempts == 1)

    // Second Dictation: a new session tries the load once more, and only once.
    let second = transcriber.session(terms: [], priority: .live)
    capture(clip) { second.append($0) }
    let secondError = await errorThrown { try await second.finish(clip) }
    let secondLoad = secondError as? LoadFailure
    #expect(secondLoad == LoadFailure(attempt: 2))
    let secondAttempts = attempts.withLock { count in count }
    #expect(secondAttempts == 2)
}

@Test(.timeLimit(.minutes(1)))
func fnDownsFailedLoadIsTheDictationsOneAttempt() async throws {
    let folder = try wholeModelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let attempts = Mutex(0)
    let transcriber = ParakeetTranscriber(folder: folder, load: { _ in
        throw LoadFailure(attempt: attempts.withLock { count -> Int in
            count += 1
            return count
        })
    })
    let grid = WindowDecoder.grid
    let clip = AudioClip(samples: [Int16](repeating: 0, count: grid.window + 2 * grid.stride))

    // A load that failed before this Dictation began is not its answer: the model may be fixed since.
    _ = try? await transcriber.load()
    // The Dictation starts, and fn-down's own load fails (a fast failure, before the first
    // window is in). Its windows answer with that failure rather than loading again.
    let session = transcriber.session(terms: [], priority: .live)
    _ = try? await transcriber.load()
    capture(clip) { session.append($0) }
    let error = await errorThrown { try await session.finish(clip) }
    #expect(error as? LoadFailure == LoadFailure(attempt: 2))
    #expect(attempts.withLock { $0 } == 2)
}
