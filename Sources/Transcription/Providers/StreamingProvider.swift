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
    /// Sent right after connect. Keywords (up to `Preferences.speechTerms` Lexicon Terms) go here.
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
/// (isFinal false / true). The cloud's model text is every final joined in order,
/// complete once the provider ends the session after `finalize()`: a final is one
/// finished stretch of speech, never a running total.
enum ProviderEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
    /// No more finals will come. Before `finalize()` this means the provider cut the session short.
    case sessionEnded
    case error(String)
    case ignore
}
