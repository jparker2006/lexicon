import Foundation
import Testing
@testable import LexiconUI
import LexiconDomain
import WordStore

// The Lexicon page's Remove on one heard-as form (#342): that form's Rule goes,
// and the entry keeps its Term and its other forms. Whole-entry Delete is not
// here. The controller is never shown; the form buttons are pressed with
// performClick, and the test waits on the removal the press starts.

/// A controller over `store`, never shown, with its list read.
@MainActor
private func openedController(_ store: Lexicon) async -> LexiconWindowController {
    let controller = LexiconWindowController(lexicon: store, onClose: {})
    // The controller starts a read of its own when it is made, and a read that
    // finishes after a later one has started is dropped. The second read below
    // starts after that one, so it is the list left standing.
    await controller.reload()
    await controller.reload()
    return controller
}

/// The cell the table builds for the entry spelled `spelling`.
@MainActor
private func entryCell(_ controller: LexiconWindowController, spelling: String) throws -> EntryCell {
    let row = try #require(controller.shown.firstIndex { $0.spelling == spelling }, "The page shows \(spelling)")
    return try #require(controller.tableView(controller.table, viewFor: nil, row: row) as? EntryCell)
}

/// Presses the Remove button for one heard-as form, then waits for the removal and the reread it starts.
@MainActor
private func removeForm(_ heard: String, from spelling: String, in controller: LexiconWindowController) async throws {
    let label = "Remove heard-as form \(heard) from \(spelling)"
    let cell = try entryCell(controller, spelling: spelling)
    let button = try #require(cell.formButtons.first { $0.accessibilityLabel() == label }, "A Remove button for \(heard)")
    button.performClick(nil)
    await controller.pending?.value
}

@MainActor
@Suite struct DictionaryRemoveFormTests {
    @Test func removingOneHeardAsFormKeepsTheEntryItsTermAndItsOtherForms() async throws {
        let store = try Lexicon(paths: .temporary())
        try await store.add(Term(text: "SUPABASE"))
        try await store.add(Rule(heard: "super base", written: "SUPABASE"))
        try await store.add(Rule(heard: "super bass", written: "SUPABASE"))
        let controller = await openedController(store)

        try await removeForm("super bass", from: "SUPABASE", in: controller)

        #expect(await store.rules == [Rule(heard: "super base", written: "SUPABASE")])
        #expect(await store.terms == [Term(text: "SUPABASE")])
        #expect(controller.shown.map { LexiconText.title(for: $0) } == ["SUPABASE (heard as: super base)"])
    }

    @Test func aLearnedMarkStaysOnItsOwnFormWhenAnotherFormIsRemoved() async throws {
        let store = try Lexicon(paths: .temporary())
        try await store.add(Rule(heard: "super base", written: "SUPABASE", source: .learned))
        try await store.add(Rule(heard: "super bass", written: "SUPABASE"))
        let controller = await openedController(store)

        try await removeForm("super bass", from: "SUPABASE", in: controller)

        #expect(await store.rules == [Rule(heard: "super base", written: "SUPABASE", source: .learned)])
        #expect(controller.shown.map { LexiconText.title(for: $0) } == ["SUPABASE (heard as: ✨ super base)"])
        let cell = try entryCell(controller, spelling: "SUPABASE")
        #expect(cell.formLabels.map(\.stringValue) == ["heard as: ✨ super base"])
    }

    // Removing an entry's only record removes the entry, so it asks first, as Delete does.
    @Test func removingTheLastHeardAsFormAsksBeforeTheEntryGoes() async throws {
        let store = try Lexicon(paths: .temporary())
        try await store.add(Rule(heard: "codecs", written: "Codex"))
        let controller = await openedController(store)

        try await removeForm("codecs", from: "Codex", in: controller)

        #expect(await store.rules == [Rule(heard: "codecs", written: "Codex")], "Nothing is removed before a confirmation")
        #expect(controller.window?.attachedSheet != nil, "A confirmation names Codex before the entry goes")
    }

    @Test func aPlainSpellingHasNoFormButtonsOrFormLabels() async throws {
        let store = try Lexicon(paths: .temporary())
        try await store.add(Term(text: "gstack"))
        let controller = await openedController(store)

        let cell = try entryCell(controller, spelling: "gstack")
        #expect(cell.formButtons.isEmpty)
        #expect(cell.formLabels.isEmpty)
    }

    @Test func removingAFormLeavesACaseOnlyVariantEntryAsItIs() async throws {
        let store = try Lexicon(paths: .temporary())
        try await store.add(Rule(heard: "codecs", written: "Codex"))
        try await store.add(Rule(heard: "kodex", written: "CODEX"))
        let controller = await openedController(store)
        // Codex and CODEX are two entries: a spelling is exact, case included.
        #expect(Set(controller.shown.map(\.spelling)) == ["Codex", "CODEX"])

        try await removeForm("codecs", from: "Codex", in: controller)

        #expect(await store.rules == [Rule(heard: "kodex", written: "CODEX")])
        #expect(controller.shown.map { LexiconText.title(for: $0) } == ["CODEX (heard as: kodex)"])
    }

    @Test func eachFormButtonIsNamedForItsFormAndItsSpelling() async throws {
        let store = try Lexicon(paths: .temporary())
        try await store.add(Term(text: "SUPABASE"))
        try await store.add(Rule(heard: "super base", written: "SUPABASE"))
        try await store.add(Rule(heard: "super bass", written: "SUPABASE", source: .learned))
        let controller = await openedController(store)

        let cell = try entryCell(controller, spelling: "SUPABASE")
        #expect(cell.formButtons.map { $0.accessibilityIdentifier() }
            == Array(repeating: AccessibilityID.lexiconRemoveForm, count: 2))
        #expect(cell.formButtons.map { $0.accessibilityLabel() } == [
            "Remove heard-as form super base from SUPABASE",
            "Remove heard-as form super bass from SUPABASE",
        ])
        #expect(cell.formLabels.map(\.stringValue) == ["heard as: super base", "heard as: ✨ super bass"])
    }
}
