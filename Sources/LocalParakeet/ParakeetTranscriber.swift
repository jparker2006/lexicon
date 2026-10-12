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
///
/// Long audio is read in FluidAudio's own grid of 15 s windows overlapping by
/// 2 s, each decoded on its own and then merged on the overlap. Each window is
/// decoded as soon as it is captured, so a 20-minute Dictation waits at fn-up
/// for its last window and the merge, not for 93 windows. The windows and the
/// merge are the one-shot path's, so the words are too. The streaming encoder
/// is not used: it is a second 565 MB download and decodes worse.
public actor ParakeetTranscriber: LocalTranscriber {
    public nonisolated let model: LocalModel = .parakeetUnified
    let folder: URL
    private var manager: UnifiedAsrManager?
    /// A load in flight, shared by every caller that needs the model meanwhile.
    private var loading: Task<UnifiedAsrManager, any Error>?
    /// Joins windows into text. Read from the vocabulary on the first load and
    /// kept: a few KB, and a join never needs the model itself.
    private var words: (merge: SeamMerge, tokenizer: Tokenizer)?
    /// Every model call (one window, unload) runs here: one at a time, live first.
    private let jobs = LocalJobQueue()

    /// Weights live in `<root>/models/` (this module names that folder). If they
    /// are missing, `load()` throws `LocalModelNotInstalled` and the Dictation
    /// waits for a model.
    public init(paths: AppPaths) {
        folder = Self.folder(paths)
    }

    static func folder(_ paths: AppPaths) -> URL {
        modelsFolder(paths).appending(path: Repo.parakeetUnified.folderName, directoryHint: .isDirectory)
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

    /// `UnifiedAsrManager`'s offline window: 15 s and a 2 s overlap, whole 80 ms
    /// encoder frames. Its windows must be this grid's, or the merge would not
    /// see the overlaps it expects.
    static let grid: WindowGrid = {
        let config = UnifiedConfig()
        let window = 15 * config.sampleRate / config.frameSamples * config.frameSamples
        let overlap = min(2 * config.sampleRate, window / 2) / config.frameSamples * config.frameSamples
        return WindowGrid(window: window, overlap: overlap)
    }()

    public var isResident: Bool { manager != nil }

    /// Every required file is whole. FluidAudio streams each file into
    /// `<name>.partial` inside its final `.mlmodelc` folder and renames it once
    /// complete, so an interrupted download leaves folders that exist but are
    /// not whole: the same test FluidAudio uses (a compiled model's
    /// `coremldata.bin`, no `.partial` left) tells them apart.
    public static func isInstalled(paths: AppPaths) -> Bool { isComplete(folder(paths)) }

    /// Points `paths`' models at `source`'s with a link, unless `paths` has
    /// models of its own: a scratch data root uses the installed weights rather
    /// than downloading about 614 MB again.
    public static func shareModels(of source: AppPaths, with paths: AppPaths) throws {
        let models = modelsFolder(paths)
        guard (try? models.checkResourceIsReachable()) != true,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: models.path)) == nil else { return }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: models, withDestinationURL: modelsFolder(source))
    }

    static func isComplete(_ folder: URL) -> Bool {
        let files = FileManager.default
        let whole = requiredFiles.allSatisfy { name in
            let file = folder.appending(path: name)
            return name.hasSuffix(".mlmodelc")
                ? files.fileExists(atPath: file.appending(path: "coremldata.bin").path)
                : files.fileExists(atPath: file.path)
        }
        guard whole, let all = files.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        return !all.contains { ($0 as? URL)?.pathExtension == "partial" }
    }

    public func load() async throws {
        _ = try await loaded()
    }

    /// Waits for any running transcription, so the model never goes away under one.
    public func unload() async {
        await jobs.run(.background) { await self.dropModel() }
    }

    /// `terms` is ignored: no FluidAudio boosting (see the type's doc).
    public nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WindowedSession(grid: Self.grid,
                        decode: { samples, start in try await self.decode(samples, at: start, priority: priority) },
                        join: { windows in try await self.join(windows) })
    }

    /// One window, as its own job: a live Dictation waits behind at most one
    /// window of a background Retry, never the whole clip.
    private func decode(_ samples: [Int16], at start: Int, priority: LocalPriority) async throws
        -> [SeamMerge.TokenWindow] {
        try await jobs.run(priority) {
            // Its Dictation was cancelled, or the cloud won, while it waited its turn.
            try Task.checkCancellation()
            let manager = try await self.loaded()
            let window = try await manager.transcribeWithTimings(Self.floats(samples))
            // Back to encoder frames counted from the clip's start, which the merge matches on.
            let config = await manager.config
            let secondsPerFrame = Double(config.frameSamples) / Double(config.sampleRate)
            let offset = start / config.frameSamples
            return window.tokenTimings.map {
                (token: $0.tokenId, timestamp: offset + Int(($0.startTime / secondsPerFrame).rounded()),
                 confidence: $0.confidence, duration: 0)
            }
        }
    }

    private func join(_ windows: [[SeamMerge.TokenWindow]]) throws -> String {
        guard !windows.isEmpty else { return "" }
        guard let words else { throw ASRError.notInitialized }  // a decoded window loaded them
        return words.tokenizer.decode(ids: words.merge.merge(windows).map(\.token))
    }

    private func loaded() async throws -> UnifiedAsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let folder = folder
        guard Self.isComplete(folder) else { throw LocalModelNotInstalled(model) }
        let task = Task {
            let manager = UnifiedAsrManager(encoderPrecision: .int8)
            try await manager.loadModels(from: folder)
            return manager
        }
        loading = task
        defer { loading = nil }
        let manager = try await task.value
        if words == nil {
            let tokenizer = try Tokenizer(vocabPath: folder.appending(path: ModelNames.ParakeetUnified.vocab))
            words = (SeamMerge(vocabulary: tokenizer.vocabulary), tokenizer)
        }
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

    /// Model install (first-run setup, or `scripts/install-model.sh`): downloads
    /// the offline int8 tier (about 614 MB) into `<root>/models/` and loads it
    /// once. Never on the Dictation path. Takes a `CloudAccess` like every
    /// network use: Private mode blocks downloads too, and a revoke mid-download
    /// (Private mode turned on) cancels it, which FluidAudio's downloader honors.
    ///
    /// A `models` link to another data folder whose install is not whole (the
    /// dev folder links to the daily one's) is replaced by a folder of its own
    /// first, so a dev build never downloads into the daily copy's folder.
    ///
    /// The Neural Engine compile that first load does (about 25 s) is cached
    /// per executable and per macOS build, under
    /// `~/Library/Caches/<process>/com.apple.e5rt.e5bundlecache/`, so a compile
    /// here does not warm another process: the app compiles on its own first load.
    public static func install(paths: AppPaths, access: CloudAccess,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        // Whole already: nothing to fetch, and FluidAudio's repair never runs through a link into the daily folder.
        guard !isInstalled(paths: paths) else { return }
        let models = modelsFolder(paths)
        try await access.untilRevoked {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: models.path)) != nil {
                // Removes the link only, never what it points at.
                try FileManager.default.removeItem(at: models)
            }
            let manager = UnifiedAsrManager(encoderPrecision: .int8)
            try await manager.loadModels(to: models, progressHandler: { progress($0.fractionCompleted) })
            await manager.cleanup()
        }
    }
}
