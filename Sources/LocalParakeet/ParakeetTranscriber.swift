// Started from Muesli's ParakeetUnifiedBackend.swift
// (https://github.com/Muesli-HQ/muesli, MIT License).
// Copyright (c) 2026 Pranav Hari

import FluidAudio
import Foundation
public import LexiconDomain
import Synchronization
public import Transcription

/// Parakeet Unified 0.6B (English) on the Neural Engine via FluidAudio (#9),
/// with the offline int8 encoder: punctuation and capitals, no word boosting
/// (it over-fired in measurement; Rules fix words after transcription).
/// About 80 ms per clip of 6 s or less, warm load 0.4-0.6 s, weights under
/// `<root>/models/` (never in the bundle).
///
/// Long audio is read in FluidAudio's own grid of 15 s windows overlapping by
/// 2 s, each decoded on its own (`WindowDecoder`) and then merged on the overlap
/// (`SeamMerge`). Each window is decoded as soon as it is captured, so a
/// 20-minute Dictation waits at fn-up for its last window and the merge, not for
/// 93 windows. The windows and the merge are the one-shot path's, so the words
/// are too. The streaming encoder is not used: it is a second 565 MB download
/// and decodes worse.
public actor ParakeetTranscriber: LocalTranscriber {
    public nonisolated let model: LocalModel = .parakeetUnified
    let folder: URL
    private var decoder: WindowDecoder?
    /// A load in flight, shared by every caller that needs the model meanwhile.
    private var loading: Task<WindowDecoder, any Error>?
    /// The last load's failure and when it came, so a Dictation whose fn-down load
    /// failed answers with that failure instead of loading again.
    private var lastFailure: (error: any Error, at: ContinuousClock.Instant)?
    /// Joins windows into text. Read from the vocabulary on the first join and
    /// kept: a few KB, and a join never needs the model itself.
    private var words: SeamMerge?
    /// Every model call (one window, unload) runs here: one at a time, live first.
    private let jobs = LocalJobQueue()
    private let loadDecoder: @Sendable (URL) async throws -> WindowDecoder

    /// Weights live in `<root>/models/` (this module names that folder). If they
    /// are missing, `load()` throws `LocalModelNotInstalled` and the Dictation
    /// waits for a model.
    public init(paths: AppPaths) {
        self.init(folder: Self.folder(paths), load: WindowDecoder.load(from:))
    }

    init(folder: URL, load: @escaping @Sendable (URL) async throws -> WindowDecoder) {
        self.folder = folder
        loadDecoder = load
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

    public var isResident: Bool { decoder != nil }

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
    /// Only a cancelled unload, which keeps the model, can throw.
    public func unload() async {
        try? await jobs.run(.background) { await self.dropModel() }
    }

    /// `terms` is ignored: no FluidAudio boosting (see the type's doc).
    public nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        let failure = LoadFailure()
        return WindowedSession(grid: WindowDecoder.grid,
                               decode: { samples, start in
                                   try await self.decode(samples, at: start, priority: priority, failure: failure)
                               },
                               join: { windows in try await self.join(windows) })
    }

    /// One window, as its own job: a live Dictation waits behind at most one
    /// window of a background Retry, never the whole clip.
    private func decode(_ samples: [Int16], at start: Int, priority: LocalPriority, failure: LoadFailure) async throws
        -> [SeamMerge.TokenWindow] {
        try await jobs.run(priority) {
            // Its Dictation was cancelled, or the cloud won, while it waited its turn.
            try Task.checkCancellation()
            return try await self.loaded(failure).decode(samples, at: start)
        }
    }

    /// A load that failed, kept for the rest of one Dictation: a model folder that
    /// looks whole but won't load would otherwise start a fresh load (a CoreML
    /// compile) for every 15 s window while Jake talks. The next Dictation makes a
    /// new session, so the next fn-down tries again.
    final class LoadFailure: Sendable {
        /// When the Dictation began: a load that failed since (its fn-down load) counts as its own.
        let since = ContinuousClock.now
        let error = Mutex<(any Error)?>(nil)
    }

    private func loaded(_ failure: LoadFailure) async throws -> WindowDecoder {
        if let error = failure.error.withLock({ $0 }) { throw error }
        if decoder == nil, loading == nil, let last = lastFailure, last.at >= failure.since {
            failure.error.withLock { $0 = last.error }
            throw last.error
        }
        do {
            return try await loaded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure.error.withLock { $0 = error }
            throw error
        }
    }

    private func join(_ windows: [[SeamMerge.TokenWindow]]) throws -> String {
        guard !windows.isEmpty else { return "" }
        if words == nil {
            let tokenizer = try Tokenizer(vocabPath: folder.appending(path: ModelNames.ParakeetUnified.vocab))
            words = SeamMerge(vocabulary: tokenizer.vocabulary)
        }
        return words!.text(windows)
    }

    private func loaded() async throws -> WindowDecoder {
        if let decoder { return decoder }
        if let loading { return try await loading.value }
        let folder = folder
        guard Self.isComplete(folder) else { throw LocalModelNotInstalled(model) }
        let load = loadDecoder
        let task = Task { try await load(folder) }
        loading = task
        defer { loading = nil }
        do {
            let decoder = try await task.value
            self.decoder = decoder
            lastFailure = nil
            return decoder
        } catch {
            lastFailure = (error, .now)
            throw error
        }
    }

    /// Lets go of the CoreML models; they are freed with the last reference.
    private func dropModel() async {
        if let loading { _ = try? await loading.value }
        decoder = nil
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
                               progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws {
        try await install(paths: paths, access: access, progress: progress) { models, progress in
            let manager = UnifiedAsrManager(encoderPrecision: .int8)
            try await manager.loadModels(to: models, progressHandler: { report in
                // The CoreML compile after the last file (about 25 s on a new build) is not a download.
                if case .compiling = report.phase {
                    progress(.preparing)
                } else {
                    progress(.downloading(report.fractionCompleted))
                }
            })
            await manager.cleanup()
        }
    }

    /// `download` fetches and prepares the model into the `models` folder it is
    /// given; tests pass one that never touches the network.
    static func install(paths: AppPaths, access: CloudAccess,
                        progress: @escaping @Sendable (ModelInstallProgress) -> Void,
                        download: @escaping @Sendable (_ models: URL,
                                                       _ progress: @escaping @Sendable (ModelInstallProgress) -> Void)
                            async throws -> Void) async throws {
        // Whole already: nothing to fetch, and FluidAudio's repair never runs through a link into the daily folder.
        guard !isInstalled(paths: paths) else { return }
        let models = modelsFolder(paths)
        try await access.untilRevoked {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: models.path)) != nil {
                // Removes the link only, never what it points at.
                try FileManager.default.removeItem(at: models)
            }
            try await download(models, progress)
        }
    }
}
