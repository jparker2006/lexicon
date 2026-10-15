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
    var requiresAcknowledgment: Bool { get }
    func connectRequest(key: String) -> URLRequest
    /// Sent right after connect. Keywords (up to `Preferences.speechTerms` Lexicon Terms) go here.
    func sessionStart(key: String, terms: [Term]) -> ProviderMessage?
    func audio(_ chunk: PCMChunk) -> ProviderMessage
    /// Sent the instant the feed ends (manual finalize mode; never server VAD).
    func finalize() -> ProviderMessage
    func parse(_ message: ProviderMessage) -> ProviderEvent
}

enum ProviderMessage: Sendable {
    case text(String)
    case binary(Data)
}

/// Partials replace the previous hypothesis. Finals are finished stretches;
/// `.completed` also ends this connection's answer without waiting for close.
/// CloudSession joins only finals, and keeps rollover answers intermediate.
enum ProviderEvent: Sendable, Equatable {
    case acknowledged
    case partial(String)
    case final(String)
    /// The complete answer for this connection, before its normal socket close.
    case completed(String)
    /// No more finals will come. Before `finalize()` this means the provider cut the session short.
    case sessionEnded
    case error(String)
    case ignore
}
