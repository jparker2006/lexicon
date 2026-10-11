import Foundation
import Synchronization
import LexiconDomain

/// One Dictation's stream to one cloud provider, written once for every adapter.
/// Opens at fn-down so the cold TLS overlaps speech, sends the session start
/// with keywords, then each chunk as it is captured, and the provider's finalize
/// the moment the feed ends. Ends with every final joined, or a failure.
///
/// Cut at once, socket closed: access revoked (Private mode, an always-private
/// app), a finalized segment that trips the Secret guard (which revokes), a
/// provider or socket error, or the race no longer needing it (`close`).
///
/// No reconnect after a failure: the local model is already racing, so a second
/// connection could only answer after local has won. With no local model the
/// Dictation waits and is transcribed again once the network returns.
final class CloudSession: Sendable {
    enum End: Sendable {
        case text(String)
        case failed(String)
    }

    let model: CloudModel
    /// Partials and finals while Jake talks, minus any final the Secret guard
    /// caught. Finishes when the session ends.
    let segments: AsyncStream<SpeechSegment>
    private let outgoing: AsyncStream<PCMChunk>.Continuation
    private let run: Task<End, Never>

    init(model: CloudModel, access: CloudAccess, terms: [Term], link: CloudLink) {
        self.model = model
        let (segments, segmentsIn) = AsyncStream<SpeechSegment>.makeStream()
        let (audio, audioIn) = AsyncStream<PCMChunk>.makeStream()
        self.segments = segments
        outgoing = audioIn
        let provider = link.adapter(model)
        run = Task {
            defer {
                segmentsIn.finish()
                audioIn.finish()  // later chunks are dropped instead of held for a dead socket
            }
            guard let key = access.key(.speech(model)) else {
                return .failed(access.revoked.map { "access revoked: \($0.rawValue)" } ?? "no key")
            }
            let socket: any CloudSocket
            do {
                socket = try await link.connect(provider.connectRequest(key: key))
            } catch {
                return .failed("connect: \(error)")
            }
            return await Self.stream(audio, over: socket, provider: provider, access: access, terms: terms,
                                     segments: segmentsIn)
        }
    }

    /// One captured chunk, queued until the socket takes it. Dropped once the session ended.
    func send(_ chunk: PCMChunk) { outgoing.yield(chunk) }

    /// Recording stopped: finalize goes out right after the chunks already queued.
    func audioEnded() { outgoing.finish() }

    var result: End { get async { await run.value } }

    /// The race was decided without the cloud, or the Dictation was cancelled.
    func close() { run.cancel() }

    private enum Step: Sendable {
        case sent
        case serverEnded([String])
        case ended(End)
        case revoked(AccessRevoked?)
    }

    /// Set just before finalize goes out, so a session end that answers it is
    /// never read as the provider cutting the session short.
    private final class Finalizing: Sendable {
        let sent = Atomic(false)
    }

    private static func stream(_ audio: AsyncStream<PCMChunk>, over socket: any CloudSocket,
                               provider: any StreamingProvider, access: CloudAccess, terms: [Term],
                               segments: AsyncStream<SpeechSegment>.Continuation) async -> End {
        let finalizing = Finalizing()
        return await withTaskCancellationHandler {
            await withTaskGroup(of: Step.self) { group in
                group.addTask {
                    do {
                        if let start = provider.sessionStart(terms: terms) { try await socket.send(start) }
                        for await chunk in audio { try await socket.send(provider.audio(chunk)) }
                        // A cancelled iteration also ends the loop; that is not the end of the recording.
                        guard !Task.isCancelled else { return .sent }
                        finalizing.sent.store(true, ordering: .releasing)
                        try await socket.send(provider.finalize())
                        return .sent
                    } catch {
                        return .ended(.failed("send: \(error)"))
                    }
                }
                group.addTask {
                    var finals: [String] = []
                    do {
                        while let message = try await socket.receive() {
                            switch provider.parse(message) {
                            case .partial(let text):
                                segments.yield(SpeechSegment(text: text, isFinal: false))
                            case .final(let text):
                                // Before Cleanup sees it: a secret cuts the rest of the stream (#5).
                                if SecretGuard.matches(text) {
                                    access.revoke(.secretFound)
                                    return .revoked(.secretFound)
                                }
                                finals.append(text)
                                segments.yield(SpeechSegment(text: text, isFinal: true))
                            case .sessionEnded:
                                return .serverEnded(finals)
                            case .error(let message):
                                return .ended(.failed("provider: \(message)"))
                            case .ignore:
                                continue
                            }
                        }
                        return .serverEnded(finals)
                    } catch {
                        return .ended(.failed("receive: \(error)"))
                    }
                }
                group.addTask { .revoked(await access.whenRevoked()) }
                defer {
                    socket.close()  // first, so a pending receive returns and the group can finish
                    group.cancelAll()
                }
                while let step = await group.next() {
                    switch step {
                    case .sent, .revoked(nil):
                        continue
                    case .serverEnded(let finals):
                        guard finalizing.sent.load(ordering: .acquiring) else {
                            return .failed("session ended before finalize")
                        }
                        return .text(finals.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }.joined(separator: " "))
                    case .ended(let end):
                        return end
                    case .revoked(let reason?):
                        return .failed("access revoked: \(reason.rawValue)")
                    }
                }
                return .failed("closed")
            }
        } onCancel: {
            socket.close()
        }
    }
}
