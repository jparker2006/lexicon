import Foundation
import Synchronization
import Testing
@testable import AudioCapture
@testable import LexiconCore
import LexiconDomain

@Test(.timeLimit(.minutes(1)))
func microphoneTerminalSelectionUsesDiscardAndCancelWithoutReadingFileCompletion() async throws {
    let system = try terminalSelectionSystem()

    for expected in [RunEnd.discard, .cancel] {
        let commands = HeldRunEndStream()
        let ended = OneShot<HostTime>()
        ended.settle(nil)
        let fileEndReads = Mutex(0)
        let selection = Task {
            await system.conductor.nextEnd(commands.stream, input: .microphone(deviceUID: nil), fileEnded: {
                fileEndReads.withLock { $0 += 1 }
                _ = await commands.requested.value()
                return await ended.value()
            })
        }

        // The command reader is waiting before the end arrives. The file completion is already
        // settled nil, which makes it the stop a microphone must never consume.
        _ = await commands.requested.value()
        commands.send(expected)

        #expect(sameEnd(await selection.value, as: expected))
        #expect(fileEndReads.withLock { $0 } == 0)
    }
}

@Test(.timeLimit(.minutes(1)))
func bufferedMicrophoneDiscardAndCancelNeverReadSettledFileCompletion() async throws {
    let system = try terminalSelectionSystem()
    let ended = OneShot<HostTime>()
    ended.settle(nil)

    for expected in [RunEnd.discard, .cancel] {
        let (commands, continuation) = AsyncStream<RunEnd>.makeStream()
        continuation.yield(expected)
        continuation.finish()
        let fileEndReads = Mutex(0)

        let selected = await system.conductor.nextEnd(commands, input: .microphone(deviceUID: nil), fileEnded: {
            fileEndReads.withLock { $0 += 1 }
            return await ended.value()
        })

        #expect(sameEnd(selected, as: expected))
        #expect(fileEndReads.withLock { $0 } == 0)
    }
}

@Test(.timeLimit(.minutes(1)))
func nilFileCompletionStopsWhenNoCommandHasArrived() async throws {
    let system = try terminalSelectionSystem()
    let commands = HeldRunEndStream()
    let ended = OneShot<HostTime>()
    ended.settle(nil)
    let fileEndReads = Mutex(0)
    let selection = Task {
        await system.conductor.nextEnd(commands.stream,
                                       input: .file(URL(fileURLWithPath: "/tmp/selector.wav"), pace: .asFastAsPossible),
                                       fileEnded: {
            fileEndReads.withLock { $0 += 1 }
            _ = await commands.requested.value()
            return await ended.value()
        })
    }

    // Keep the command reader pending while the already-finished file input supplies nil.
    _ = await commands.requested.value()
    #expect(isStop(await selection.value))
    #expect(fileEndReads.withLock { $0 } == 1)
}

@Test(.timeLimit(.minutes(1)))
func fileCancelAndDiscardCancelTheLosingFileCompletionWait() async throws {
    let system = try terminalSelectionSystem()

    for expected in [RunEnd.cancel, .discard] {
        let commands = HeldRunEndStream()
        let ended = OneShot<HostTime>()
        let fileEndStarted = OneShot<Void>()
        let fileEndReturned = OneShot<Void>()
        let fileEndReads = Mutex(0)
        let selection = Task {
            await system.conductor.nextEnd(commands.stream,
                                           input: .file(URL(fileURLWithPath: "/tmp/selector.wav"), pace: .asFastAsPossible),
                                           fileEnded: {
                fileEndReads.withLock { $0 += 1 }
                fileEndStarted.settle(())
                let result = await ended.value()
                fileEndReturned.settle(())
                return result
            })
        }

        // Wait for both competing reads to be active. Ending the file wait is then cancellation,
        // driven by the explicit command rather than by elapsed time.
        _ = await commands.requested.value()
        _ = await fileEndStarted.value()
        commands.send(expected)

        #expect(sameEnd(await selection.value, as: expected))
        _ = await fileEndReturned.value()
        #expect(fileEndReads.withLock { $0 } == 1)
    }
}

private struct HeldRunEndStream: Sendable {
    let stream: AsyncStream<RunEnd>
    let requested: OneShot<Void>
    private let command: OneShot<RunEnd>

    init() {
        let requested = OneShot<Void>()
        let command = OneShot<RunEnd>()
        self.requested = requested
        self.command = command
        stream = AsyncStream(unfolding: {
            requested.settle(())
            return await command.value()
        })
    }

    func send(_ end: RunEnd) { command.settle(end) }
}

private func terminalSelectionSystem() throws -> HeadlessSystem {
    try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                            local: ScriptedTranscriber(text: "selector control"), clock: TestClock())
}

private func sameEnd(_ actual: RunEnd, as expected: RunEnd) -> Bool {
    switch (actual, expected) {
    case (.discard, .discard), (.cancel, .cancel): true
    default: false
    }
}

private func isStop(_ end: RunEnd) -> Bool {
    if case .stop = end { true } else { false }
}
