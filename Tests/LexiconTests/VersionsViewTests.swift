import Foundation
import History
import LexiconDomain
import Testing
@testable import LexiconUI

// Show Versions (#213): the earlier versions a Retry replaced, as HistoryText
// lists them and as VersionsView draws them. The Dictation is built through
// History's write API on a throwaway data folder. Nothing here shows a window;
// the sheet itself is the live app's to check.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: nil, deviceName: "Mic", storage: .onDisk, gaps: [])
private let receipt = InsertionReceipt(appBundleID: app.bundleID, fieldFingerprint: nil, caretAfter: nil,
                                       contextBefore: "", contextAfter: "", insertedAt: start)
private let rules = CleanupOutcome.rulesOnly(.off)
// Two engines, so each Retry hears with a different one than the version it replaces.
private let parakeet = SpeechModel.local(.parakeetUnified)
private let museVoice = SpeechModel.cloud(.museVoice)

/// Heard "first words" by Parakeet, then Retried twice: Muse Voice hears "second
/// words", then Parakeet hears "third words". With `fixed`, a Fix changes "second"
/// to "2nd" before the second Retry, so that earlier version's final text differs
/// from its cleaned text.
@MainActor
private func dictationRetriedTwice(fixed: Bool = false) async throws -> HistoryDetail {
    let paths = AppPaths.temporary()
    let store = try HistoryStore(paths: paths)
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.attempted(id, AttemptRecord(model: museVoice, result: .timedOut, text: nil,
                                              latency: .milliseconds(1_500), error: "deadline")))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: "first words", cleaned: "first words"), cleanup: rules,
                            model: parakeet, typing: true))
    store.record(.delivered(id, receipt, lag: .milliseconds(420)))
    store.record(.retried(id, TextVersions(model: "second words", cleaned: "second words"), cleanup: rules,
                          model: museVoice, version: UUID()))
    if fixed {
        store.record(.fixRecorded(Fix(dictation: id, kind: .respeak, source: .respeak, before: "second", after: "2nd",
                                      verdict: .proposed, at: start)))
    }
    store.record(.retried(id, TextVersions(model: "third words", cleaned: "third words"), cleanup: rules,
                          model: parakeet, version: UUID()))
    await store.flush()
    return try #require(HistoryReader(paths: paths).detail(id))
}

/// The versions view laid out and drawn with no window, as the sheet would be before
/// it is shown: the size of what was drawn. AppKit stays out of the test target's
/// imports, so the view is only reached through LexiconUI.
@MainActor
private func drawnSize(_ sections: [(label: String, text: String)]) throws -> CGSize {
    let view = VersionsView.make(sections)
    view.layoutSubtreeIfNeeded()
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.size
}

@MainActor
@Test func showVersionsListsTheCurrentTextThenEachEarlierVersionNewestFirstThenTheEngineThatLost() async throws {
    let sections = HistoryText.versions(try await dictationRetriedTwice())

    let current = sections.prefix(3)
    let labels = current.map(\.label)
    #expect(labels.count == 3 && labels[0].hasPrefix("Model") && labels[1].hasPrefix("Cleaned") && labels[2] == "Final")
    #expect(current.map(\.text) == ["third words", "third words", "third words"])

    // Each earlier version sits right after Final, under the engine that heard it.
    let replaced = sections.filter { $0.label.contains("Replaced") }
    #expect(sections.firstIndex(where: { $0.label.contains("Replaced") }) == 3)
    #expect(replaced.map(\.text) == ["second words", "first words"])
    #expect(replaced.first?.label.contains(museVoice.displayName) == true)
    #expect(replaced.last?.label.contains(parakeet.displayName) == true)

    // The engine that lost comes after every earlier version.
    #expect(sections.last.map { $0.label.hasSuffix("timed out") && !$0.label.contains("Replaced") } == true)
}

@MainActor
@Test func anEarlierVersionAFixChangedShowsBothItsTextsAndOneNoFixTouchedShowsItsTextOnce() async throws {
    let texts = HistoryText.versions(try await dictationRetriedTwice(fixed: true)).map(\.text)

    // The Fix was made on "second words" before the second Retry replaced it: both texts stay readable.
    #expect(texts.contains("second words"))
    #expect(texts.contains("2nd words"))
    // "first words" was never fixed, so its cleaned and final text are the same and it shows once.
    #expect(texts.filter { $0 == "first words" }.count == 1)
}

@MainActor
@Test func showVersionsDrawsEachEarlierVersionUnderItsLabelInOrder() async throws {
    let sections = HistoryText.versions(try await dictationRetriedTwice())
    let body = try #require(VersionsView.make(sections).value(forKeyPath: "documentView.string") as? String)

    let replaced = sections.filter { $0.label.contains("Replaced") }
    try #require(replaced.count == 2)
    var cursor = body.startIndex
    for piece in [replaced[0].label, replaced[0].text, replaced[1].label, replaced[1].text] {
        let found = try #require(body.range(of: piece, range: cursor..<body.endIndex), "\(piece) is drawn after what comes before it")
        cursor = found.upperBound
    }
}

@MainActor
@Test func theEarlierVersionsTakeRoomInTheRenderedVersionsView() async throws {
    let sections = HistoryText.versions(try await dictationRetriedTwice())
    let withEarlier = try drawnSize(sections)
    let currentOnly = try drawnSize(Array(sections.prefix(3)))

    #expect(withEarlier.width > 0 && withEarlier.height > 0)
    #expect(withEarlier.height > currentOnly.height)
}
