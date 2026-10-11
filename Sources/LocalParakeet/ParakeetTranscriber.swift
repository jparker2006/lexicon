import Foundation
public import LexiconDomain
public import Transcription

// The real adapter imports FluidAudio here and nowhere else:
//   import FluidAudio
// Package.swift adds `.product(name: "FluidAudio", package: "FluidAudio")` to this
// target only. The sketch has no external dependencies, so the bodies are empty.

/// Parakeet Unified 0.6B (English) on the Neural Engine via FluidAudio (#9).
/// ~80 ms per clip of 6 s or less, ~130 MB resident when loaded, warm load
/// 0.4-0.6 s, 586 MB of weights under `<root>/models/` (never in the bundle).
public actor ParakeetTranscriber: LocalTranscriber {
    public let model: LocalModel = .parakeetUnified

    /// Weights live in `<root>/models/` (this module names that folder). If they
    /// are missing, `load()` throws and Transcription treats local as unavailable.
    public init(paths: AppPaths) { fatalError("not implemented") }

    public var isResident: Bool { fatalError("not implemented") }
    public func load() async throws { fatalError("not implemented") }
    public func unload() async { fatalError("not implemented") }
    /// One job at a time; a `.live` call jumps every queued `.background` call
    /// (a small two-lane queue in this actor, drained live-first).
    public func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String {
        // TODO: enqueue in the lane for `priority`; when the ANE is free, run the head of the
        // live lane first, else the background lane; FluidAudio transcribe(clip.samples).
        fatalError("not implemented")
    }

    /// Model install (M2 onboarding or settings): download 586 MB, then the
    /// one-time CoreML compile (~27 s). Never on the Dictation path. Re-run in
    /// the background at launch when the compiled cache is missing (OS update).
    /// Takes a `CloudAccess` like every network use: Private mode blocks downloads too (#5).
    public static func install(paths: AppPaths, access: CloudAccess, progress: @Sendable (Double) -> Void) async throws {
        fatalError("not implemented")
    }
}
