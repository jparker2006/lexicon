import Foundation
import LexiconDomain

/// One cloud provider's wire protocol, and nothing else. Each adapter is one
/// file of ~100-200 lines (#8): it builds the URLRequest, the session-start
/// message (with keywords), encodes PCM, names the finalize message, and parses
/// server messages into `ProviderEvent`. Sockets, retries, timing and the race
/// live in `CloudSession` and `SpeechEngine`, written once.
///
/// Internal: a provider's wire types can never leak out of Transcription.
protocol StreamingProvider: Sendable {
    func connectRequest(key: String) -> URLRequest
    /// Sent right after connect. Keywords (50-100 Lexicon terms: #10) go here.
    func sessionStart(terms: [Term]) -> ProviderMessage?
    func audio(_ chunk: PCMChunk) -> ProviderMessage
    /// Sent the instant the feed ends (manual finalize mode; never server VAD).
    func finalize() -> ProviderMessage
    func parse(_ message: ProviderMessage) -> ProviderEvent
}

enum ProviderMessage: Sendable {
    case text(String)
    case binary(Data)
}

/// `.partial` and `.final` become `SpeechSegment`s on `SpeechAttempt.segments`
/// (isFinal false / true); only the provider's last final after `finalize()` is the model text.
enum ProviderEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
    case sessionEnded
    case error(String)
    case ignore
}

/// The shared socket plumbing: URLSessionWebSocketTask, a send loop over the
/// feed, a receive loop, connect-time buffering of early chunks. Recorded
/// server messages replace `transport` in tests (no keys, no network).
final class CloudSession: Sendable {
    init(provider: any StreamingProvider, access: CloudAccess, model: CloudModel, terms: [Term]) {
        fatalError("not implemented")
    }
}
