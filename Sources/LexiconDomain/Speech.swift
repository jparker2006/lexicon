import Foundation

/// Cloud speech models Lexicon can stream to. THE list of providers.
///
/// Adding a provider is one enum case here. The build then fails in two places
/// until the case is whole: `retention` below, and
/// `Transcription/Providers/ProviderCatalog.swift`'s exhaustive switch until the
/// new adapter file is written. The model picker, the Keychain account name and
/// the stored model id all derive from this enum. Nothing else lists providers.
public enum CloudModel: String, Sendable, Codable, CaseIterable {
    /// The cloud default from M2 (#67): wss://api.meta.ai/v1/asr/realtime, keywords at session start.
    case museVoice = "meta.muse-voice-transcribe-1.0"

    public var displayName: String {
        switch self {
        case .museVoice: "Meta Muse Voice"
        }
    }

    /// Whether the provider keeps nothing Lexicon sends it: zero retention on,
    /// training opted out. An eval sends Test set audio only to a `.confirmed`
    /// model (#166). Set `.confirmed` only once Jake has confirmed the provider's
    /// terms for his account; a new case starts `.unconfirmed`. Cartesia Ink and ElevenLabs offer zero retention on
    /// Enterprise plans only, and Meta's is organization-only (#111).
    public var retention: ZeroRetention {
        switch self {
        case .museVoice: .unconfirmed
        }
    }
}

public enum ZeroRetention: Sendable, Hashable {
    case confirmed
    case unconfirmed
}

/// On-device models. Exact model is #9; default per the local-model research is
/// Parakeet Unified 0.6B (English) via FluidAudio on the Neural Engine.
public enum LocalModel: String, Sendable, Codable, CaseIterable {
    case parakeetUnified = "parakeet-unified-0.6b-en"

    public var displayName: String {
        switch self {
        case .parakeetUnified: "Parakeet (on this Mac)"
        }
    }
}

/// A local model install, as it goes: the files downloading (0...1 of the whole
/// install), then the model being prepared for this Mac until it loads.
public enum ModelInstallProgress: Sendable, Hashable {
    case downloading(Double)
    case preparing
}

/// Any model that can produce text for a Dictation. Stored as `id` in SQLite.
public enum SpeechModel: Hashable, Sendable {
    case cloud(CloudModel)
    case local(LocalModel)

    /// Derived, never hand-listed: the Retry model picker shows exactly this.
    public static var allCases: [SpeechModel] {
        CloudModel.allCases.map(SpeechModel.cloud) + LocalModel.allCases.map(SpeechModel.local)
    }

    public var id: String {
        switch self {
        case .cloud(let m): "cloud:" + m.rawValue
        case .local(let m): "local:" + m.rawValue
        }
    }

    public init?(id: String) {
        if let m = SpeechModel.allCases.first(where: { $0.id == id }) { self = m } else { return nil }
    }

    public var displayName: String {
        switch self {
        case .cloud(let m): m.displayName
        case .local(let m): m.displayName
        }
    }
}

/// A piece of text the cloud provider sent while Jake was still talking.
/// `isFinal == false` is a partial that the provider may still revise (the
/// indicator may show it, #18). `isFinal == true` is finalized: Cleanup cleans
/// finished sentences from these before fn-up, so only the tail waits after it.
public struct SpeechSegment: Sendable, Hashable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// One engine's run on one Dictation, winner or loser. Produced by
/// Transcription, stored by History (`attempt` table), shown in "Show versions".
/// Both cloud and local text for every Dictation: free data for #19 and the Test set.
public struct AttemptRecord: Sendable, Hashable {
    public enum Result: String, Sendable, Hashable, CaseIterable { case won, lost, failed, timedOut, cancelled }
    public let model: SpeechModel
    public let result: Result
    public let text: String?
    public let latency: Duration?
    public let error: String?
    public init(model: SpeechModel, result: Result, text: String?, latency: Duration?, error: String?) {
        self.model = model
        self.result = result
        self.text = text
        self.latency = latency
        self.error = error
    }
}
