import Foundation
import LexiconDomain

// The model side of cleanup. Internal: no wire format, prompt or model handle
// leaves this module.
//
// The on-device adapter imports Apple's FoundationModels here and nowhere else:
//   import FoundationModels
// It does not compile against the macOS 15.5 SDK in today's Command Line Tools,
// so the sketch leaves the body empty (same treatment as FluidAudio).

/// One request: the sentences to clean, what came before them, and the words the
/// model must not "fix" (Lexicon terms: names, code terms).
struct CleanupRequest: Sendable, Hashable {
    /// Ruled sentences to clean, in order.
    var sentences: [String]
    /// Already-cleaned sentences before them (context only; never returned).
    var before: [String]
    var terms: [Term]
    var app: AppContext
}

/// An LLM that cleans sentences. Returns one cleaned string per input sentence,
/// or throws; the session turns every throw into a rules-only outcome.
protocol CleanupModel: Sendable {
    var engine: CleanupEngine { get }
    /// Optional warm-up at fn-down (TLS to OpenRouter; model prewarm on device).
    func prewarm() async
    func clean(_ request: CleanupRequest) async throws -> [String]
}

/// OpenRouter chat completions over plain URLSession, non-streaming:
/// `POST https://openrouter.ai/api/v1/chat/completions` with the pinned fast
/// providers (`provider.order`, `allow_fallbacks: false`), temperature 0, a
/// JSON array of sentences in and out, `zdr: true` on every request (#5). Key:
/// `access.key(.cleanup, sending: text)`, so the Secret guard sees the text first.
/// Cannot be constructed without a `CloudAccess`: Private mode and the toggle
/// off are the same "no access" for cloud cleanup.
struct OpenRouterCleanup: CleanupModel {
    let model: CloudCleanupModel
    let access: CloudAccess
    let session: URLSession

    var engine: CleanupEngine { .cloud(model) }
    func prewarm() async { fatalError("not implemented") }
    func clean(_ request: CleanupRequest) async throws -> [String] {
        // TODO: build the request (system prompt: fix punctuation, casing, fillers and
        // self-repairs; keep every content word; keep these terms verbatim: request.terms),
        // POST with a timeout just past the session deadline, decode choices[0].message.content.
        fatalError("not implemented")
    }
}

/// Apple Foundation Models on this Mac (macOS 26): Private mode and offline.
/// Same prompt shape as the cloud model; nothing leaves the Mac.
struct OnDeviceCleanup: CleanupModel {
    var engine: CleanupEngine { .onDevice }
    func prewarm() async { fatalError("not implemented") }
    func clean(_ request: CleanupRequest) async throws -> [String] {
        // TODO: SystemLanguageModel.default availability check (throw when unavailable);
        // LanguageModelSession(instructions:).respond(to:) with guided output of [String].
        fatalError("not implemented")
    }
}
