import Foundation
import Synchronization
import LexiconDomain

/// Owns the cloud leg, including its bounded audio queue and post-answer drain.
/// The answer and the socket lifetime end separately: normal close must never
/// hold a completed transcript behind the speech race deadline.
final class CloudSession: Sendable {
    enum End: Sendable {
        case text(String)
        case failed(String)
    }

    struct Policy: Sendable {
        var maxBufferedBytes = 160_000
        var rolloverSamples = 55 * 60 * PCM16k.sampleRate
        var closeGrace: Duration = .seconds(5)
        var paceAudio = true
    }

    let model: CloudModel
    let segments: AsyncStream<SpeechSegment>
    private let control: Control
    private let run: Task<Void, Never>

    init(model: CloudModel, access: CloudAccess, terms: [Term], link: CloudLink) {
        self.model = model
        let (segments, output) = AsyncStream<SpeechSegment>.makeStream()
        self.segments = segments
        let control = Control(limit: link.policy.maxBufferedBytes, segments: output)
        self.control = control
        run = Task {
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            try await Self.connections(model: model, access: access, terms: terms,
                                                       link: link, control: control)
                        } catch {
                            control.stop(.failed(Self.describe(error)))
                        }
                    }
                    group.addTask {
                        if let reason = await access.whenRevoked() {
                            control.stop(.failed("access revoked: \(reason.rawValue)"))
                        }
                    }
                    await group.next()
                    control.stop(.failed("closed"))
                    group.cancelAll()
                }
            } onCancel: {
                control.stop(.failed("closed"))
            }
        }
    }

    /// Includes the chunk currently awaiting a send, so a stalled socket cannot
    /// move audio out of the accounting while still retaining it.
    var bufferedBytes: Int { control.audio.bufferedBytes }

    func send(_ chunk: PCMChunk) {
        if !control.audio.append(chunk) {
            control.stop(.failed("cloud audio buffer full"))
            run.cancel()
        }
    }

    func audioEnded() { control.audio.finish() }
    var result: End { get async { await control.answer() } }
    func waitUntilClosed() async { await run.value }

    func close() {
        control.stop(.failed("closed"))
        run.cancel()
    }

    private static func connections(model: CloudModel, access: CloudAccess, terms: [Term],
                                    link: CloudLink, control: Control) async throws {
        let provider = link.adapter(model)
        var pending: PCMChunk?
        var finals: [String] = []
        while true {
            try permitted(access, control: control)
            guard let key = access.key(.speech(model)) else { throw Failure("no key") }
            let request = provider.connectRequest(key: key)
            // Request preparation and key lookup can both yield control to a
            // revocation boundary. Check again immediately before connecting.
            try permitted(access, control: control)
            let socket = try await link.connect(request)
            guard control.install(socket) else { throw CancellationError() }
            try permitted(access, control: control)
            let safeTerms = terms.filter { !SecretGuard.matches($0.text) }
            if let start = provider.sessionStart(key: key, terms: safeTerms) {
                try permitted(access, control: control)
                try await socket.send(start)
            }
            if provider.requiresAcknowledgment {
                try await acknowledge(socket, provider: provider, access: access, control: control)
            }
            pending = try await exchange(pending: pending, socket: socket, provider: provider,
                                         access: access, link: link, control: control, finals: &finals)
            // A healthy socket gets its normal close. The injected deadline also
            // bounds an intermediate rollover connection that never closes.
            if provider.requiresAcknowledgment {
                let normalClose = await drain(socket, clock: link.clock, grace: link.policy.closeGrace,
                                               answer: pending == nil ? .text(join(finals)) : nil, control: control)
                if pending != nil && !normalClose { throw Failure("rollover connection did not close normally") }
            } else if pending == nil {
                control.publish(.text(join(finals)))
                control.segments.finish()
            }
            socket.close()
            control.clearSocket()
            if pending == nil { return }
        }
    }

    private static func acknowledge(_ socket: any CloudSocket, provider: any StreamingProvider,
                                    access: CloudAccess, control: Control) async throws {
        while let message = try await socket.receive() {
            try permitted(access, control: control)
            switch provider.parse(message) {
            case .acknowledged: return
            case .ignore: continue
            default: throw Failure("provider acknowledgment failed")
            }
        }
        throw Failure("closed before acknowledgment")
    }

    private enum Step: Sendable {
        case sent(PCMChunk?)
        case received([String])
    }

    private final class Finalizing: Sendable {
        let sent = Atomic(false)
    }

    private static func exchange(pending: PCMChunk?, socket: any CloudSocket, provider: any StreamingProvider,
                                 access: CloudAccess, link: CloudLink, control: Control,
                                 finals: inout [String]) async throws -> PCMChunk? {
        let finalizing = Finalizing()
        let previous = finals
        return try await withThrowingTaskGroup(of: Step.self) { group in
            group.addTask {
                .sent(try await transmit(pending: pending, socket: socket, provider: provider,
                                         access: access, link: link, control: control, finalizing: finalizing))
            }
            group.addTask {
                .received(try await receive(socket, provider: provider, access: access, control: control,
                                            finalizing: finalizing, previous: previous))
            }
            var next: PCMChunk?
            var sent = false
            var received = false
            do {
                while let step = try await group.next() {
                    switch step {
                    case .sent(let chunk): next = chunk; sent = true
                    case .received(let text): finals.append(contentsOf: text); received = true
                    }
                    if sent && received { return next }
                }
                throw Failure("closed")
            } catch {
                socket.close()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func transmit(pending: PCMChunk?, socket: any CloudSocket, provider: any StreamingProvider,
                                 access: CloudAccess, link: CloudLink, control: Control,
                                 finalizing: Finalizing) async throws -> PCMChunk? {
        var chunk = pending
        var samples = 0
        var previousDuration: Duration = .zero
        while true {
            if chunk == nil { chunk = await control.audio.next() }
            guard let current = chunk else { break }
            if samples > 0 && current.samples.count > max(0, link.policy.rolloverSamples - samples) { break }
            if provider.requiresAcknowledgment && link.policy.paceAudio && previousDuration > .zero {
                try await link.clock.sleep(for: previousDuration)
            }
            try permitted(access, control: control)
            try await socket.send(provider.audio(current))
            control.audio.release(current.samples.count * 2)
            samples += current.samples.count
            previousDuration = .seconds(Double(current.samples.count) / Double(PCM16k.sampleRate))
            chunk = nil
        }
        try permitted(access, control: control)
        finalizing.sent.store(true, ordering: .releasing)
        try await socket.send(provider.finalize())
        return chunk
    }

    private static func receive(_ socket: any CloudSocket, provider: any StreamingProvider,
                                access: CloudAccess, control: Control, finalizing: Finalizing,
                                previous: [String]) async throws -> [String] {
        var finals: [String] = []
        while let message = try await socket.receive() {
            try permitted(access, control: control)
            let event = provider.parse(message)
            switch event {
            case .partial(let text):
                control.segments.yield(SpeechSegment(text: text, isFinal: false))
            case .final(let text), .completed(let text):
                // Test the accumulated text too, including an uninterrupted
                // token at a session boundary, without changing the matcher.
                let accumulated = previous + finals + [text]
                if SecretGuard.matches(join(accumulated)) || SecretGuard.matches(accumulated.joined()) {
                    access.revoke(.secretFound)
                    throw Failure("access revoked: secretFound")
                }
                finals.append(text)
                control.segments.yield(SpeechSegment(text: text, isFinal: true))
                if case .completed = event {
                    guard finalizing.sent.load(ordering: .acquiring) else { throw Failure("session ended before finalize") }
                    return finals
                }
            case .sessionEnded:
                guard finalizing.sent.load(ordering: .acquiring) else { throw Failure("session ended before finalize") }
                return finals
            case .error: throw Failure("provider error")
            case .acknowledged, .ignore: continue
            }
        }
        guard !provider.requiresAcknowledgment, finalizing.sent.load(ordering: .acquiring) else {
            throw Failure("session ended before final")
        }
        return finals
    }

    private static func drain<C: Clock>(_ socket: any CloudSocket, clock: C, grace: Duration,
                                        answer: End?, control: Control) async -> Bool where C.Duration == Duration {
        let deadline = clock.now.advanced(by: grace)
        if let answer {
            control.publish(answer)
            control.segments.finish()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    while try await socket.receive() != nil {}
                    return true
                } catch { return false }
            }
            group.addTask {
                try? await clock.sleep(until: deadline, tolerance: nil)
                return false
            }
            let normalClose = await group.next() ?? false
            socket.close()
            group.cancelAll()
            return normalClose
        }
    }

    private static func permitted(_ access: CloudAccess, control: Control) throws {
        try Task.checkCancellation()
        if let reason = access.revoked { throw Failure("access revoked: \(reason.rawValue)") }
        if control.stopped { throw CancellationError() }
    }

    private static func join(_ finals: [String]) -> String {
        finals.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    /// Attempts may enter History, so transport failures never retain a raw
    /// provider body, URL, credential or custom error description.
    private static func describe(_ error: any Error) -> String {
        if let failure = error as? Failure { return failure.message }
        if let error = error as? URLError { return "URLError \(error.code.rawValue)" }
        return "cloud transport failed"
    }

    private final class Control: Sendable {
        private struct State {
            var answer: End?
            var waiters: [CheckedContinuation<End, Never>] = []
            var socket: (any CloudSocket)?
            var stopped = false
        }
        private let state = Mutex(State())
        let audio: AudioQueue
        let segments: AsyncStream<SpeechSegment>.Continuation

        init(limit: Int, segments: AsyncStream<SpeechSegment>.Continuation) {
            audio = AudioQueue(limit: limit)
            self.segments = segments
        }

        var stopped: Bool { state.withLock { $0.stopped } }

        func answer() async -> End {
            await withCheckedContinuation { waiter in
                let answer = state.withLock { state -> End? in
                    if let answer = state.answer { return answer }
                    state.waiters.append(waiter)
                    return nil
                }
                if let answer { waiter.resume(returning: answer) }
            }
        }

        func publish(_ answer: End) {
            let waiters = state.withLock { state -> [CheckedContinuation<End, Never>] in
                guard state.answer == nil else { return [] }
                state.answer = answer
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: answer) }
        }

        func install(_ socket: any CloudSocket) -> Bool {
            let accepted = state.withLock { state -> Bool in
                guard !state.stopped else { return false }
                state.socket = socket
                return true
            }
            if !accepted { socket.close() }
            return accepted
        }

        func clearSocket() { state.withLock { $0.socket = nil } }

        func stop(_ answer: End) {
            let socket = state.withLock { state -> (any CloudSocket)? in
                state.stopped = true
                defer { state.socket = nil }
                return state.socket
            }
            audio.stop()
            socket?.close()
            publish(answer)
            segments.finish()
        }
    }

    private final class AudioQueue: Sendable {
        private struct State {
            var chunks: [PCMChunk] = []
            var bytes = 0
            var ended = false
            var stopped = false
        }
        private let state = Mutex(State())
        private let limit: Int
        private let changed: AsyncStream<Void>
        private let wake: AsyncStream<Void>.Continuation

        init(limit: Int) {
            self.limit = max(0, limit)
            (changed, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
        var bufferedBytes: Int { state.withLock { $0.bytes } }

        func append(_ chunk: PCMChunk) -> Bool {
            let accepted = state.withLock { state -> Bool in
                guard !state.stopped, !state.ended else { return true }
                guard chunk.samples.count <= (limit - state.bytes) / 2 else { return false }
                guard !chunk.samples.isEmpty else { return true }
                state.bytes += chunk.samples.count * 2
                state.chunks.append(chunk)
                return true
            }
            wake.yield(())
            return accepted
        }

        func next() async -> PCMChunk? {
            var changes = changed.makeAsyncIterator()
            while !Task.isCancelled {
                let next = state.withLock { state -> (PCMChunk?, Bool) in
                    if !state.chunks.isEmpty { return (state.chunks.removeFirst(), false) }
                    return (nil, state.ended || state.stopped)
                }
                if next.0 != nil || next.1 { return next.0 }
                guard await changes.next() != nil else { return nil }
            }
            return nil
        }

        func release(_ bytes: Int) { state.withLock { $0.bytes = max(0, $0.bytes - bytes) } }
        func finish() { state.withLock { $0.ended = true }; wake.yield(()) }
        func stop() {
            state.withLock { $0.stopped = true; $0.chunks = []; $0.bytes = 0 }
            wake.finish()
        }
    }
}
