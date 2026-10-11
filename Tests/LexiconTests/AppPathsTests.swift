import Foundation
import Testing
import LexiconDomain

private let support = URL(filePath: "/Users/someone/Library/Application Support", directoryHint: .isDirectory)

@Test func dailyAndDevBuildsGetSeparateDataFolders() {
    let daily = AppPaths.forBundle(id: AppPaths.dailyBundleID, in: support)
    let dev = AppPaths.forBundle(id: AppPaths.devBundleID, in: support)
    #expect(daily.root.path == "/Users/someone/Library/Application Support/Lexicon")
    #expect(dev.root.path == "/Users/someone/Library/Application Support/Lexicon Dev")
}

@Test func anUnknownBundleIDNeverLandsInTheDailyFolder() {
    let other = AppPaths.forBundle(id: "dev.jparker.lexicon.experiment", in: support)
    #expect(other.root.path == "/Users/someone/Library/Application Support/dev.jparker.lexicon.experiment")
}

