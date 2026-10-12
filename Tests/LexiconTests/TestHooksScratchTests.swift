#if DEBUG
import Foundation
import Testing
@testable import LexiconCore
import LexiconDomain
import TestHooks

// A test-hooks run's scratch data root (#156): synthetic History, audio and
// Lexicon go to a folder of their own, never into the dev app's data folder,
// and never into the daily copy's.

@Test func theScratchRootIsOutsideBothDataFolders() {
    let scratch = AppPaths.scratch(forBundle: AppPaths.devBundleID).root.standardizedFileURL.path
    for id in [AppPaths.devBundleID, AppPaths.dailyBundleID] {
        let own = AppPaths.forBundle(id: id).root.standardizedFileURL.path
        #expect(!scratch.hasPrefix(own) && !own.hasPrefix(scratch))
    }
    // The same folder each launch, so a relaunch finds the Dictations made before it.
    #expect(AppPaths.scratch(forBundle: AppPaths.devBundleID) == AppPaths.scratch(forBundle: AppPaths.devBundleID))
}

@Test func aTestHooksRunUsesTheScratchRootUnlessToldToUseTheDevData() {
    let root = { (arguments: [String]) in TestHookChannel.dataRoot(forBundle: AppPaths.devBundleID, arguments: arguments) }
    #expect(root(["Lexicon", "--test-hooks"]) == AppPaths.scratch(forBundle: AppPaths.devBundleID))
    #expect(root(["Lexicon", "--test-hooks", "--dev-data"]) == AppPaths.forBundle(id: AppPaths.devBundleID))
}

@Test func aDictationInAScratchRunWritesOnlyUnderTheScratchRoot() async throws {
    let machine = try scratchDirectory()
    let support = machine.appending(path: "Application Support")
    let dev = AppPaths.forBundle(id: AppPaths.devBundleID, in: support)
    try FileManager.default.createDirectory(at: dev.root, withIntermediateDirectories: true)
    try Data().write(to: dev.root.appending(path: "history.sqlite"))
    let before = try contents(of: support)

    let scratch = AppPaths.scratch(forBundle: AppPaths.devBundleID, in: machine.appending(path: "T"))
    let system = try HeadlessSystem.make(paths: scratch, context: .unknown, preferences: .defaults,
                                         local: ScriptedTranscriber(text: "Ship it."))
    let wav = try writeWAV(tone(16_000), rate: 16_000, in: try scratchDirectory())
    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .inserted)
    #expect(await system.history.dictation(result.id) != nil)
    #expect(FileManager.default.fileExists(atPath: scratch.root.appending(path: "history.sqlite").path))
    #expect(try contents(of: support) == before)
}

/// Every path under `folder`, with its size: what a run may not change.
private func contents(of folder: URL) throws -> [String: Int] {
    var found: [String: Int] = [:]
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
    while let file = files?.nextObject() as? URL {
        found[file.path] = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
    }
    return found
}
#endif
