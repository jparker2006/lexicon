import Foundation
import Testing
import LexiconDomain
@testable import LocalParakeet

// The model folder on disk, and the links between data roots. A dev data root
// links to the daily copy's models so it never downloads them again, and an install
// must never write through such a link into the daily folder. Every test works in a
// scratch folder it removes, and the download an install gets is a fake: nothing
// here touches the network, a microphone or real data.

/// A complete model set, as FluidAudio leaves it once every file is whole: each
/// required file, and each `.mlmodelc` a folder holding its `coremldata.bin`.
/// The files are empty because nothing here loads a model.
private func writeModelSet(in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ParakeetTranscriber.requiredFiles {
        if name.hasSuffix(".mlmodelc") {
            let compiled = folder.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data().write(to: compiled.appending(path: "coremldata.bin"))
        } else {
            try Data().write(to: folder.appending(path: name))
        }
    }
}

/// A fresh scratch folder for one test, removed when the test ends, also when it fails.
private func withScratch(_ body: (URL) async throws -> Void) async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

/// `paths`' models folder as a link to `source`'s, the way a dev data root is set up.
private func linkModels(of paths: AppPaths, to source: AppPaths) throws {
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: ParakeetTranscriber.modelsFolder(paths),
                                               withDestinationURL: ParakeetTranscriber.modelsFolder(source))
}

/// Where `url` links to, or nil when it is not a link. A real folder is not a link:
/// `destinationOfSymbolicLink` throws for it, which gives nil.
private func linkTarget(_ url: URL) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

private func isFolder(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

/// Every path under `folder`, sorted. A test compares it before and after to show
/// that nothing in the folder was written, moved or removed.
private func listing(of folder: URL) -> [String] {
    let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    return (all?.compactMap { ($0 as? URL)?.path } ?? []).sorted()
}

/// The access an install gets. A download needs no key and Private mode is off, so
/// the access is granted; `ModelDownloadTests` makes its access the same way.
private let noKeys: @Sendable (CredentialID) -> String? = { _ in nil }

private func openAccess() throws -> CloudAccess {
    try #require(CloudAccess.granted(by: .defaults, for: .modelInstall, keys: noKeys))
}

/// What the fake download was asked, for the test to check after `install` returns.
private actor DownloadCalls {
    struct Call: Sendable {
        let folder: URL
        /// Where `paths/models` linked to when the download began. A link still there
        /// would send the download's files into another data root's folder.
        let linkedTo: String?
    }
    private(set) var started: [Call] = []
    func record(_ call: Call) { started.append(call) }
}

/// The download a test injects in place of the network. It records what it was
/// asked, then writes a whole model set under the `models` folder it is given, as
/// the real download would.
private func fakeDownload(writingFor paths: AppPaths, recordingIn calls: DownloadCalls)
    -> @Sendable (URL, @escaping @Sendable (ModelInstallProgress) -> Void) async throws -> Void {
    { models, _ in
        await calls.record(.init(folder: models, linkedTo: linkTarget(models)))
        let set = models.appending(path: ParakeetTranscriber.folder(paths).lastPathComponent,
                                   directoryHint: .isDirectory)
        try writeModelSet(in: set)
    }
}

// MARK: Whether a model folder is whole

@Test func aWholeModelFolderIsInstalled() async throws {
    try await withScratch { dir in
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        try writeModelSet(in: ParakeetTranscriber.folder(paths))
        #expect(ParakeetTranscriber.isComplete(ParakeetTranscriber.folder(paths)))
        #expect(ParakeetTranscriber.isInstalled(paths: paths))
    }
}

@Test func aModelFolderMissingAnyRequiredFileIsNotInstalled() async throws {
    try await withScratch { dir in
        // A fresh folder per file, so a failure names the file that was missing.
        for (index, name) in ParakeetTranscriber.requiredFiles.enumerated() {
            let paths = AppPaths(root: dir.appending(path: "missing-\(index)", directoryHint: .isDirectory))
            let folder = ParakeetTranscriber.folder(paths)
            try writeModelSet(in: folder)
            try FileManager.default.removeItem(at: folder.appending(path: name))
            #expect(!ParakeetTranscriber.isComplete(folder), "\(name) is missing")
            #expect(!ParakeetTranscriber.isInstalled(paths: paths), "\(name) is missing")
        }
    }
}

@Test func aCompiledModelWithoutItsCoreMLDataIsNotInstalled() async throws {
    try await withScratch { dir in
        // The folder is there, but the file that makes it a compiled model is not.
        let compiled = ParakeetTranscriber.requiredFiles.filter { $0.hasSuffix(".mlmodelc") }
        #expect(!compiled.isEmpty)
        for (index, name) in compiled.enumerated() {
            let paths = AppPaths(root: dir.appending(path: "no-data-\(index)", directoryHint: .isDirectory))
            let folder = ParakeetTranscriber.folder(paths)
            try writeModelSet(in: folder)
            try FileManager.default.removeItem(at: folder.appending(path: name).appending(path: "coremldata.bin"))
            #expect(!ParakeetTranscriber.isComplete(folder), "\(name) has no coremldata.bin")
            #expect(!ParakeetTranscriber.isInstalled(paths: paths), "\(name) has no coremldata.bin")
        }
    }
}

@Test func aLeftoverPartialAnywhereInsideMakesAModelFolderIncomplete() async throws {
    try await withScratch { dir in
        // FluidAudio streams each file into `<name>.partial` and renames it once whole.
        // A leftover is tested beside the files and deep inside each compiled model,
        // since the check looks at every level of the folder.
        var leftovers = ["leftover.partial"]
        for name in ParakeetTranscriber.requiredFiles {
            leftovers.append("\(name).partial")
            if name.hasSuffix(".mlmodelc") { leftovers.append("\(name)/weights/weight.bin.partial") }
        }
        for (index, leftover) in leftovers.enumerated() {
            let paths = AppPaths(root: dir.appending(path: "partial-\(index)", directoryHint: .isDirectory))
            let folder = ParakeetTranscriber.folder(paths)
            try writeModelSet(in: folder)
            // The control: before the leftover, the same folder is whole.
            #expect(ParakeetTranscriber.isComplete(folder))
            let stray = folder.appending(path: leftover)
            try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: stray)
            #expect(!ParakeetTranscriber.isComplete(folder), "\(leftover) left behind")
            #expect(!ParakeetTranscriber.isInstalled(paths: paths), "\(leftover) left behind")
        }
    }
}

@Test func anEmptyOrMissingModelFolderIsNotInstalled() async throws {
    try await withScratch { dir in
        let missing = AppPaths(root: dir.appending(path: "missing", directoryHint: .isDirectory))
        #expect(!ParakeetTranscriber.isComplete(ParakeetTranscriber.folder(missing)))
        #expect(!ParakeetTranscriber.isInstalled(paths: missing))

        let empty = AppPaths(root: dir.appending(path: "empty", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: ParakeetTranscriber.folder(empty),
                                                withIntermediateDirectories: true)
        #expect(!ParakeetTranscriber.isComplete(ParakeetTranscriber.folder(empty)))
        #expect(!ParakeetTranscriber.isInstalled(paths: empty))
    }
}

// MARK: Sharing the models with a dev data root

@Test func shareModelsLinksADataRootWithNoModelsToTheSourcesModels() async throws {
    try await withScratch { dir in
        let source = AppPaths(root: dir.appending(path: "daily", directoryHint: .isDirectory))
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        try writeModelSet(in: ParakeetTranscriber.folder(source))

        // The dev root does not exist yet: sharing creates it.
        try ParakeetTranscriber.shareModels(of: source, with: paths)

        #expect(linkTarget(ParakeetTranscriber.modelsFolder(paths))
                == ParakeetTranscriber.modelsFolder(source).path)
        #expect(ParakeetTranscriber.isInstalled(paths: paths))
    }
}

@Test func shareModelsLeavesADataRootWithItsOwnModelsAlone() async throws {
    try await withScratch { dir in
        let source = AppPaths(root: dir.appending(path: "daily", directoryHint: .isDirectory))
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        try writeModelSet(in: ParakeetTranscriber.folder(source))
        try writeModelSet(in: ParakeetTranscriber.folder(paths))
        let before = listing(of: ParakeetTranscriber.modelsFolder(paths))

        try ParakeetTranscriber.shareModels(of: source, with: paths)

        // Its own models are a real folder, not a link, and nothing in them changed.
        #expect(linkTarget(ParakeetTranscriber.modelsFolder(paths)) == nil)
        #expect(listing(of: ParakeetTranscriber.modelsFolder(paths)) == before)
    }
}

@Test func shareModelsLeavesAnExistingLinkAloneWithoutAnError() async throws {
    try await withScratch { dir in
        let source = AppPaths(root: dir.appending(path: "daily", directoryHint: .isDirectory))
        let other = AppPaths(root: dir.appending(path: "other", directoryHint: .isDirectory))
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        try writeModelSet(in: ParakeetTranscriber.folder(other))
        try linkModels(of: paths, to: other)

        // The link points somewhere other than `source`, so a replacement would show.
        try ParakeetTranscriber.shareModels(of: source, with: paths)

        #expect(linkTarget(ParakeetTranscriber.modelsFolder(paths))
                == ParakeetTranscriber.modelsFolder(other).path)
    }
}

// MARK: Install with the network injected out

@Test func installReplacesALinkToAnIncompleteInstallWithItsOwnFolder() async throws {
    try await withScratch { dir in
        let source = AppPaths(root: dir.appending(path: "daily", directoryHint: .isDirectory))
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        // The daily copy's install is not whole: one stray file and no model set.
        let dailyModels = ParakeetTranscriber.modelsFolder(source)
        let marker = ParakeetTranscriber.folder(source).appending(path: "marker.txt")
        try FileManager.default.createDirectory(at: ParakeetTranscriber.folder(source),
                                                withIntermediateDirectories: true)
        try Data("daily copy".utf8).write(to: marker)
        try linkModels(of: paths, to: source)
        let before = listing(of: dailyModels)
        let calls = DownloadCalls()
        let access = try openAccess()

        try await ParakeetTranscriber.install(paths: paths, access: access, progress: { _ in },
                                              download: fakeDownload(writingFor: paths, recordingIn: calls))

        // The download runs once, into the dev root's own folder, with the link already gone.
        // Had the link survived, the fake's writes would land in the daily copy below.
        #expect(await calls.started.map { $0.folder.path } == [ParakeetTranscriber.modelsFolder(paths).path])
        #expect(await calls.started.map(\.linkedTo) == [nil])
        #expect(linkTarget(ParakeetTranscriber.modelsFolder(paths)) == nil)
        #expect(isFolder(ParakeetTranscriber.modelsFolder(paths)))
        #expect(ParakeetTranscriber.isInstalled(paths: paths))
        // The daily copy's folder and its file are exactly as they were.
        #expect(listing(of: dailyModels) == before)
        let text = try String(contentsOf: marker, encoding: .utf8)
        #expect(text == "daily copy")
    }
}

@Test func installLeavesALinkToAWholeInstallAlone() async throws {
    try await withScratch { dir in
        let source = AppPaths(root: dir.appending(path: "daily", directoryHint: .isDirectory))
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        try writeModelSet(in: ParakeetTranscriber.folder(source))
        try linkModels(of: paths, to: source)
        let calls = DownloadCalls()
        let access = try openAccess()

        // Whole through the link already, so install returns without downloading.
        try await ParakeetTranscriber.install(paths: paths, access: access, progress: { _ in },
                                              download: fakeDownload(writingFor: paths, recordingIn: calls))

        #expect(await calls.started.isEmpty)
        #expect(linkTarget(ParakeetTranscriber.modelsFolder(paths))
                == ParakeetTranscriber.modelsFolder(source).path)
    }
}

@Test func installDownloadsOnceWhenThereAreNoModels() async throws {
    try await withScratch { dir in
        let paths = AppPaths(root: dir.appending(path: "dev", directoryHint: .isDirectory))
        let calls = DownloadCalls()
        let access = try openAccess()

        try await ParakeetTranscriber.install(paths: paths, access: access, progress: { _ in },
                                              download: fakeDownload(writingFor: paths, recordingIn: calls))

        #expect(await calls.started.map { $0.folder.path } == [ParakeetTranscriber.modelsFolder(paths).path])
        #expect(linkTarget(ParakeetTranscriber.modelsFolder(paths)) == nil)
        #expect(ParakeetTranscriber.isInstalled(paths: paths))
    }
}

// FluidAudio spends the first half of its fraction on the download and reports nothing
// while it compiles, so the last file landing is the only sign that the install is
// preparing. Counting the download to 1 at that point keeps the bar from stopping at 50%.
@Test func theInstallSaysPreparingOnceTheLastFileLandsAndCountsTheDownloadToAHundred() {
    #expect(ParakeetTranscriber.installStep(fraction: 0, filesDone: 0, of: 4) == .downloading(0))
    #expect(ParakeetTranscriber.installStep(fraction: 0.25, filesDone: 2, of: 4) == .downloading(0.5))
    #expect(ParakeetTranscriber.installStep(fraction: 0.5, filesDone: 3, of: 4) == .downloading(1.0))
    #expect(ParakeetTranscriber.installStep(fraction: 0.5, filesDone: 4, of: 4) == .preparing)
    #expect(ParakeetTranscriber.installStep(fraction: 0.5, filesDone: 0, of: 0) == .preparing)
}
