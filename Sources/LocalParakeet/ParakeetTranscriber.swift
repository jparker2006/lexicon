// Started from Muesli's ParakeetUnifiedBackend.swift
// (https://github.com/Muesli-HQ/muesli, MIT License).
// Copyright (c) 2026 Pranav Hari

import Accelerate
import FluidAudio
import Foundation
public import LexiconDomain
public import Transcription

/// Parakeet Unified 0.6B (English) on the Neural Engine via FluidAudio (#9),
/// with the offline int8 encoder: punctuation and capitals, no word boosting
/// (it over-fired in measurement; Rules fix words after transcription).
/// About 80 ms per clip of 6 s or less, warm load 0.4-0.6 s, weights under
/// `<root>/models/` (never in the bundle).
public actor ParakeetTranscriber: LocalTranscriber {
    public nonisolated let model: LocalModel = .parakeetUnified
    let folder: URL
    private var manager: UnifiedAsrManager?
    /// A load in flight, shared by every caller that needs the model meanwhile.
    private var loading: Task<UnifiedAsrManager, any Error>?
    /// Every model call (transcribe, unload) runs here: one at a time, live first.
    private let jobs = LocalJobQueue()

    /// Weights live in `<root>/models/` (this module names that folder). If they
    /// are missing, `load()` throws `LocalModelNotInstalled` and the Dictation
    /// waits for a model.
    public init(paths: AppPaths) {
        folder = Self.modelsFolder(paths).appending(path: Repo.parakeetUnified.folderName, directoryHint: .isDirectory)
    }

    static func modelsFolder(_ paths: AppPaths) -> URL {
        paths.root.appending(path: "models", directoryHint: .isDirectory)
    }

    /// The offline int8 tier only: the streaming and fp16 encoders are never fetched.
    static let requiredFiles = [
        ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8),
        ModelNames.ParakeetUnified.decoderFile,
        ModelNames.ParakeetUnified.jointDecisionFile,
        ModelNames.ParakeetUnified.vocab,
    ]

    public var isResident: Bool { manager != nil }

    public func load() async throws {
        _ = try await loaded()
    }

    /// Waits for any running transcription, so the model never goes away under one.
    public func unload() async {
        await jobs.run(.background) { await self.dropModel() }
    }

    /// `terms` is ignored: no FluidAudio boosting (see the type's doc).
    public func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String {
        try await jobs.run(priority) {
            let manager = try await self.loaded()
            return try await manager.transcribe(Self.floats(clip.samples))
        }
    }

    private func loaded() async throws -> UnifiedAsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let folder = folder
        guard Self.requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: folder.appending(path: $0).path) })
        else { throw LocalModelNotInstalled(model) }
        let task = Task {
            let manager = UnifiedAsrManager(encoderPrecision: .int8)
            try await manager.loadModels(from: folder)
            return manager
        }
        loading = task
        defer { loading = nil }
        let manager = try await task.value
        self.manager = manager
        return manager
    }

    private func dropModel() async {
        if let loading { _ = try? await loading.value }
        let dropped = manager
        manager = nil
        // Releases the CoreML models now rather than whenever the last reference goes.
        await dropped?.cleanup()
    }

    /// Int16 PCM to the [-1, 1) floats FluidAudio takes.
    static func floats(_ samples: [Int16]) -> [Float] {
        var floats = [Float](repeating: 0, count: samples.count)
        vDSP.convertElements(of: samples, to: &floats)
        vDSP.multiply(1 / 32768, floats, result: &floats)
        return floats
    }

    /// Model install (onboarding or `scripts/install-model.sh` until it exists):
    /// downloads the offline int8 tier into `<root>/models/`, then the one-time
    /// CoreML compile (about 27 s). Never on the Dictation path. Takes a
    /// `CloudAccess` like every network use: Private mode blocks downloads too (#5).
    public static func install(paths: AppPaths, access: CloudAccess,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard access.revoked == nil else { throw CancellationError() }
        let manager = UnifiedAsrManager(encoderPrecision: .int8)
        try await manager.loadModels(to: modelsFolder(paths), progressHandler: { progress($0.fractionCompleted) })
        await manager.cleanup()
    }
}
