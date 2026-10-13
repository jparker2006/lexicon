import Foundation
import Testing
@testable import LexiconCore
@testable import AppText
import Cleanup
import LexiconDomain

// Re-speak's pure seams (#83), no mic, keys, network or Accessibility:
// where a Dictation's text sits in a field now (DictationPlace.locate), and the
// headless destination's one field, read and replaced the way a Re-speak drives it.

private let editor = "com.example.editor"

private func receipt(caretAfter: Int?, contextBefore: String = "", fingerprint: String? = "field-1",
                     bundleID: String? = editor) -> InsertionReceipt {
    InsertionReceipt(appBundleID: bundleID, fieldFingerprint: fingerprint, caretAfter: caretAfter,
                     contextBefore: contextBefore, contextAfter: "", insertedAt: Date(timeIntervalSince1970: 0))
}

private func field(_ text: String, offset: Int = 0, fingerprint: String? = "field-1", bundleID: String? = editor) -> FieldText {
    FieldText(text: text, offset: offset, selection: nil, bundleID: bundleID, fieldFingerprint: fingerprint)
}

@Suite struct RespeakPureTests {

    // MARK: DictationPlace.locate

    /// "I saw a cat." was typed after "Note: " (caret 18) and still sits there: UTF-16 6..<18.
    @Test func locateFindsTheTextAtItsCaret() {
        let found = DictationPlace.locate("I saw a cat.", receipt: receipt(caretAfter: 18, contextBefore: "Note: "),
                                          in: field("Note: I saw a cat."))
        #expect(found == TextSpan(location: 6, length: 12))
    }

    // Each guard test first shows the same receipt finds the text, so the nil is a guard and not
    // what a stub returns. At the head the positive line is the one that fails.

    @Test func locateIsNilWhenTheReceiptHasNoFingerprint() {
        let text = "I saw a cat."
        let here = field("Note: I saw a cat.")
        #expect(DictationPlace.locate(text, receipt: receipt(caretAfter: 18, contextBefore: "Note: "), in: here)
                == TextSpan(location: 6, length: 12))
        #expect(DictationPlace.locate(text, receipt: receipt(caretAfter: 18, contextBefore: "Note: ", fingerprint: nil),
                                      in: here) == nil)
    }

    @Test func locateIsNilWhenTheFieldIsAnotherField() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 18, contextBefore: "Note: ")
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.")) == TextSpan(location: 6, length: 12))
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.", fingerprint: "field-2")) == nil)
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.", fingerprint: nil)) == nil)
    }

    @Test func locateIsNilInAnotherApp() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 18, contextBefore: "Note: ")
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.")) == TextSpan(location: 6, length: 12))
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.", bundleID: "com.example.other")) == nil)
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.", bundleID: nil)) == nil)
    }

    /// Typed after "Note: " at caret 18; Jake then typed "Hey " at the start, so the text moved right
    /// to 10 and the caret no longer ends it. The context ("...Note: ") finds it.
    @Test func locateFollowsTheContextWhenJakeTypedBefore() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 18, contextBefore: "Note: ")
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.")) == TextSpan(location: 6, length: 12))
        #expect(DictationPlace.locate(text, receipt: r, in: field("Hey Note: I saw a cat.")) == TextSpan(location: 10, length: 12))
    }

    /// Two "Dog." Dictations in "Dog. Dog.": each receipt's caret and context name its own.
    /// After Jake types "X" at the start, neither caret ends its text any more. The second receipt's
    /// context still picks the second (the first "Dog." is preceded by "X", not "Dog. "). The first
    /// receipt has no context to tell the two apart, so the nearest caretAfter decides: measured to
    /// the span's end, 5 is one away from caret 4 and 10 is six, so the first "Dog." wins.
    @Test func locateTellsTwoIdenticalDictationsApart() {
        let dog = "Dog."
        let first = receipt(caretAfter: 4)
        let second = receipt(caretAfter: 9, contextBefore: "Dog. ")
        #expect(DictationPlace.locate(dog, receipt: first, in: field("Dog. Dog.")) == TextSpan(location: 0, length: 4))
        #expect(DictationPlace.locate(dog, receipt: second, in: field("Dog. Dog.")) == TextSpan(location: 5, length: 4))
        #expect(DictationPlace.locate(dog, receipt: first, in: field("XDog. Dog.")) == TextSpan(location: 1, length: 4))
        #expect(DictationPlace.locate(dog, receipt: second, in: field("XDog. Dog.")) == TextSpan(location: 6, length: 4))
    }

    @Test func locateIsNilWhenTheTextIsGone() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 18, contextBefore: "Note: ")
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.")) == TextSpan(location: 6, length: 12))
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a dog.")) == nil)
    }

    /// The emoji is two UTF-16 units, so the text starts at 3 and the caret is 15. After "Hey " is
    /// typed first the text starts at 7, and only the context (which ends in the emoji) finds it.
    @Test func locateCountsUTF16UnitsPastEmoji() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 15, contextBefore: "🙂 ")
        #expect(DictationPlace.locate(text, receipt: r, in: field("🙂 I saw a cat.")) == TextSpan(location: 3, length: 12))
        #expect(DictationPlace.locate(text, receipt: r, in: field("Hey 🙂 I saw a cat.")) == TextSpan(location: 7, length: 12))
    }

    /// The field is a window that starts at field offset 1_000, and "I saw a cat." sits at window
    /// position 4 (after "Hey "). The span is the field's, so the caret route compares field offsets.
    @Test func locateInAWindowReturnsFieldOffsets() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 1_000 + 4 + text.utf16.count)
        #expect(DictationPlace.locate(text, receipt: r, in: field("Hey I saw a cat.", offset: 1_000))
                == TextSpan(location: 1_004, length: 12))
    }

    /// Jake typed before the Dictation, so its caret is stale; the context "Note: " finds it in the
    /// window, and the span it returns is the field's (1_000 + 6), not the window's (6).
    @Test func locateInAWindowFollowsTheContextToAFieldOffset() {
        let text = "I saw a cat."
        let r = receipt(caretAfter: 1_030, contextBefore: "Note: ")
        #expect(DictationPlace.locate(text, receipt: r, in: field("Note: I saw a cat.", offset: 1_000))
                == TextSpan(location: 1_006, length: 12))
    }

    // MARK: FieldWindow and FieldText.reading (#83, a field too long to read whole)

    /// A field no longer than the cap is read whole. Passes at the head, where the stub already
    /// returns the whole field: a guard for the fix, not a red line.
    @Test func windowSpanIsTheWholeFieldWhenItFits() {
        #expect(FieldWindow.span(count: 150_000, around: 10, cap: 200_000) == TextSpan(location: 0, length: 150_000))
        #expect(FieldWindow.span(count: 200_000, around: 150_000, cap: 200_000) == TextSpan(location: 0, length: 200_000))
    }

    /// Anchor 400_000 in a 500_000 field, cap 200_000: the window ends 2_000 past the anchor and is cap long.
    /// Anchor near the start and anchor at the end clamp to the field's ends.
    @Test func windowSpanIsCapUnitsAndHoldsTheAnchorWhenTheFieldIsLonger() {
        #expect(FieldWindow.span(count: 500_000, around: 400_000, cap: 200_000) == TextSpan(location: 202_000, length: 200_000))
        #expect(FieldWindow.span(count: 500_000, around: 1_000, cap: 200_000) == TextSpan(location: 0, length: 200_000))
        #expect(FieldWindow.span(count: 500_000, around: 500_000, cap: 200_000) == TextSpan(location: 300_000, length: 200_000))
    }

    /// Whatever the anchor, the window is cap long, inside the field, and holds the anchor
    /// (a caret at the very end of the field counts as held).
    @Test func windowSpanAlwaysHoldsTheAnchorInsideTheField() {
        for anchor in [0, 1, 1_000, 99_999, 100_000, 250_000, 499_999, 500_000] {
            let span = FieldWindow.span(count: 500_000, around: anchor, cap: 200_000)
            #expect(span.length == 200_000)
            #expect(span.location >= 0 && span.location + span.length <= 500_000)
            #expect(span.location <= anchor && anchor <= span.location + span.length)
        }
    }

    /// Reads `window` as a field window at offset 1_000 in the editor, with a fixed fingerprint.
    private func read(_ window: String, selection: TextSpan?) -> FieldText? {
        FieldText.reading(window, offset: 1_000, selection: selection, bundleID: editor, fieldFingerprint: "field-1")
    }

    /// The selection's text comes from the window, so no second read can disagree with it.
    @Test func readingTakesTheSelectionsTextFromTheWindow() {
        let window = "the cat saw the cat"
        let span = TextSpan(location: 1_016, length: 3)
        #expect(read(window, selection: span)
                == FieldText(text: window, offset: 1_000, selection: FieldSelection(span: span, text: "cat"),
                             bundleID: editor, fieldFingerprint: "field-1"))
    }

    @Test func readingWithoutASelectionHasNone() {
        let window = "the cat saw the cat"
        #expect(read(window, selection: nil)
                == FieldText(text: window, offset: 1_000, selection: nil, bundleID: editor, fieldFingerprint: "field-1"))
    }

    /// The inside selection is the positive line (red at the head). The two outside spans are
    /// guards: one ends before the window, the other starts inside it and runs past its end.
    @Test func readingIsNilWhenTheSelectionRunsOutsideTheWindow() {
        let window = "the cat saw the cat"
        #expect(read(window, selection: TextSpan(location: 1_016, length: 3))
                == FieldText(text: window, offset: 1_000, selection: FieldSelection(span: TextSpan(location: 1_016, length: 3), text: "cat"),
                             bundleID: editor, fieldFingerprint: "field-1"))
        #expect(read(window, selection: TextSpan(location: 900, length: 3)) == nil)
        #expect(read(window, selection: TextSpan(location: 1_017, length: 5)) == nil)
    }

    /// "🙂" is two UTF-16 units, so "cat" starts at 1_003 in the field, not at a Character's index.
    @Test func readingCountsUTF16UnitsPastAnEmoji() {
        let window = "🙂 cat"
        #expect(read(window, selection: TextSpan(location: 1_003, length: 3))
                == FieldText(text: window, offset: 1_000, selection: FieldSelection(span: TextSpan(location: 1_003, length: 3), text: "cat"),
                             bundleID: editor, fieldFingerprint: "field-1"))
        #expect(read(window, selection: TextSpan(location: 1_000, length: 2))
                == FieldText(text: window, offset: 1_000, selection: FieldSelection(span: TextSpan(location: 1_000, length: 2), text: "🙂"),
                             bundleID: editor, fieldFingerprint: "field-1"))
    }

    // MARK: HeadlessDestination's one field

    @Test func headlessReplaceReplacesASpanThatReadsExpected() async throws {
        let destination = HeadlessDestination()
        let target = try #require(await destination.target())
        _ = await destination.insert("I saw a cat.", for: DictationID(), at: target)
        let before = await destination.fieldText
        #expect(before == "I saw a cat.")

        let outcome = await destination.replace(TextSpan(location: 8, length: 3), expected: "cat", with: "dog", at: target)
        guard case .replaced(let receipt) = outcome else { Issue.record("not replaced: \(outcome)"); return }
        #expect(receipt.caretAfter == 11)  // the end of the new words
        #expect(receipt.fieldFingerprint == "headless")
        let after = await destination.fieldText
        #expect(after == "I saw a dog.")
    }

    @Test func headlessReplaceRefusesASpanThatReadsSomethingElse() async throws {
        let destination = HeadlessDestination()
        let target = try #require(await destination.target())
        _ = await destination.insert("I saw a cat.", for: DictationID(), at: target)

        let outcome = await destination.replace(TextSpan(location: 8, length: 3), expected: "bat", with: "dog", at: target)
        #expect(outcome == .refused(.textChanged))
        let after = await destination.fieldText
        #expect(after == "I saw a cat.")
    }

    @Test func headlessReadReturnsTheFieldTheSelectionAndTheHeadlessFingerprint() async throws {
        let destination = HeadlessDestination(context: AppContext(bundleID: editor, appName: nil, windowTitle: nil,
                                                                  workingDirectory: nil))
        let typing = try #require(await destination.target())
        _ = await destination.insert("I saw a cat.", for: DictationID(), at: typing)

        // Jake selects "cat" before the Re-speak's fn-up: the target captures it.
        let span = TextSpan(location: 8, length: 3)
        await destination.select(span)
        let target = try #require(await destination.target())

        let read = await destination.read(at: target)
        #expect(read == FieldText(text: "I saw a cat.", selection: FieldSelection(span: span, text: "cat"),
                                  bundleID: editor, fieldFingerprint: "headless"))
    }

    // MARK: RespeakText.replacement

    @Test func replacementDropsTheTrailingPeriodAndLowercasesTheFirstWord() {
        #expect(RespeakText.replacement("Dog.", replacing: "cat", terms: []) == "dog")
    }

    @Test func replacementKeepsATermWrittenWithItsCapitals() {
        #expect(RespeakText.replacement("Supabase.", replacing: "super base", terms: ["Supabase"]) == "Supabase")
    }

    @Test func replacementKeepsAnUppercaseLetterInsideTheFirstWord() {
        #expect(RespeakText.replacement("GitHub.", replacing: "git hub", terms: []) == "GitHub")
    }

    @Test func replacementKeepsAnUppercaseFirstLetterWhenTheReplacedTextHasOne() {
        #expect(RespeakText.replacement("Dog.", replacing: "Cat", terms: []) == "Dog")
    }

    /// The "?" stays when the replaced words ended with one, and a plain English word is still
    /// lowercased to match the lowercase text it replaces.
    @Test func replacementKeepsAQuestionMarkTheSelectionAlsoEndsWith() {
        #expect(RespeakText.replacement("dog?", replacing: "cat?", terms: []) == "dog?")
        #expect(RespeakText.replacement("Dog?", replacing: "cat?", terms: []) == "dog?")
    }

    @Test func replacementTrimsWhitespaceAndNewlines() {
        #expect(RespeakText.replacement("  dog \n", replacing: "cat", terms: []) == "dog")
    }

    @Test func replacementIsEmptyForAPeriodAlone() {
        #expect(RespeakText.replacement(".", replacing: "cat", terms: []) == "")
    }

    // The first letter goes lower only when the replaced text starts lowercase, the first word is
    // plain English, it is not "I" or an "I'" contraction, and it is not a Term's first word (#83 review).

    /// "I." over "eye": the pronoun "I" keeps its capital even though the replaced word is lowercase.
    @Test func replacementKeepsTheWordIEvenOverALowercaseSelection() {
        #expect(RespeakText.replacement("I.", replacing: "eye", terms: [], isEnglish: { _ in true }) == "I")
    }

    @Test func replacementKeepsAnIContractionCapitalized() {
        #expect(RespeakText.replacement("I'm", replacing: "um", terms: []) == "I'm")
    }

    /// "alice" is not an English word to isEnglish, so a name Cleanup capitalized keeps its capital.
    @Test func replacementKeepsAWordThatIsNotEnglish() {
        #expect(RespeakText.replacement("Alice.", replacing: "alice", terms: [], isEnglish: { $0 != "alice" }) == "Alice")
    }

    /// The guard for the cases above: a plain English word still goes lowercase mid-sentence.
    @Test func replacementLowercasesACommonEnglishWord() {
        #expect(RespeakText.replacement("Dog.", replacing: "cat", terms: [], isEnglish: { _ in true }) == "dog")
    }

    /// "Next" is a Term, and the text is exactly that Term: its capital stays.
    @Test func replacementKeepsATermsWrittenFormWhenItStartsTheText() {
        #expect(RespeakText.replacement("Next.", replacing: "next", terms: ["Next"], isEnglish: { _ in true }) == "Next")
    }

    /// "Next" is a Term's first word and begins a longer phrase: the phrase keeps the Term's capital.
    @Test func replacementKeepsATermsFirstWordWhenMoreWordsFollow() {
        #expect(RespeakText.replacement("Next steps.", replacing: "next step", terms: ["Next"]) == "Next steps")
    }

    /// The brief's "Dog." over "Cat" case, with isEnglish given explicitly. The replaced text starts
    /// uppercase, so the English word keeps its capital too. (The older test above pins the same line.)
    @Test func replacementKeepsTheCapitalOfAWordOverAnUppercaseSelection() {
        #expect(RespeakText.replacement("Dog.", replacing: "Cat", terms: [], isEnglish: { _ in true }) == "Dog")
    }

    // The selection's own whitespace is part of the words it replaces (#83 review): a replacement
    // that drops it runs the words into their neighbours. The first-letter rule reads past it too.

    @Test func replacementKeepsTheSpaceBeforeTheReplacedWord() {
        #expect(RespeakText.replacement("Dog.", replacing: " cat", terms: []) == " dog")
    }

    @Test func replacementKeepsTheSpaceAfterTheReplacedWord() {
        #expect(RespeakText.replacement("Dog.", replacing: "cat ", terms: []) == "dog ")
    }

    @Test func replacementKeepsTheNewlineAndSpaceAroundTheReplacedWord() {
        #expect(RespeakText.replacement("Dog.", replacing: " cat\n", terms: []) == " dog\n")
    }

    /// The stop rule reads the selection's last non-whitespace character: "cat. " ends in a stop,
    /// so Cleanup's "." stays, and the trailing space stays too.
    @Test func replacementKeepsTheStopWhenTheSelectionEndsInAStopAndSpace() {
        #expect(RespeakText.replacement("Dog.", replacing: "cat. ", terms: []) == "dog. ")
    }

    // The closing mark comes from the selected words, never from the Re-speak (#83 review): the
    // Re-speak's own "." "!" or "?" is dropped, and the selection's, when its last non-whitespace
    // character is one, is kept. The Re-speak's period never stands in for the selection's "!".

    /// "Dog." over "cat!" and "cat?" ends with the selection's mark, not the Re-speak's period.
    @Test func replacementTakesTheClosingMarkOfTheSelection() {
        #expect(RespeakText.replacement("Dog.", replacing: "cat!", terms: [], isEnglish: { _ in true }) == "dog!")
        #expect(RespeakText.replacement("Dog.", replacing: "cat?", terms: [], isEnglish: { _ in true }) == "dog?")
    }

    /// "Dog?" over "cat." keeps the selection's period; the Re-speak's "?" is dropped.
    @Test func replacementKeepsThePeriodOfTheSelectionOverTheSpokenQuestion() {
        #expect(RespeakText.replacement("Dog?", replacing: "cat.", terms: [], isEnglish: { _ in true }) == "dog.")
    }

    /// Guards that pass at the head: the Re-speak's mark goes when the selection has none, and a
    /// "?" the selection and the Re-speak both end with stays, as it always did.
    @Test func replacementDropsTheSpokenMarkWhenTheSelectionHasNone() {
        #expect(RespeakText.replacement("Dog!", replacing: "cat", terms: [], isEnglish: { _ in true }) == "dog")
        #expect(RespeakText.replacement("dog?", replacing: "cat?", terms: [], isEnglish: { _ in true }) == "dog?")
    }

    /// "cat! " ends in a mark and then a space: the mark is the selection's and the space stays.
    @Test func replacementKeepsTheSelectionsMarkBeforeItsSpace() {
        #expect(RespeakText.replacement("Dog.", replacing: "cat! ", terms: [], isEnglish: { _ in true }) == "dog! ")
    }

    // The first word is judged without the punctuation after it (#83 review): "Dog," is the English
    // word "dog" with a comma, so the comma must not keep the capital. Only "," ";" ":" are stripped
    // here; an apostrophe is part of a word ("I'm"), and the "I" rule reads the bare word too.

    /// "Dog, then." over "cat": "Dog," failed isEnglish, so the capital stayed; the first word is "Dog".
    @Test func replacementLowercasesAFirstWordFollowedByAComma() {
        #expect(RespeakText.replacement("Dog, then.", replacing: "cat", terms: [],
                                        isEnglish: { $0 == "dog" || $0 == "then" }) == "dog, then")
    }

    @Test func replacementLowercasesAFirstWordFollowedBySemicolonOrColon() {
        #expect(RespeakText.replacement("Dog; then.", replacing: "cat", terms: [],
                                        isEnglish: { $0 == "dog" || $0 == "then" }) == "dog; then")
        #expect(RespeakText.replacement("Dog: then.", replacing: "cat", terms: [],
                                        isEnglish: { $0 == "dog" || $0 == "then" }) == "dog: then")
    }

    /// "I," is the pronoun "I" with a comma, so it keeps its capital as "I." does (the "I" rule reads the bare word).
    @Test func replacementKeepsTheWordIBeforeAComma() {
        #expect(RespeakText.replacement("I, then.", replacing: "eye", terms: [], isEnglish: { _ in true }) == "I, then")
    }

    /// Guard that passes at the head and after the fix: a name before a comma keeps its capital.
    @Test func replacementKeepsANameBeforeAComma() {
        #expect(RespeakText.replacement("Alice, then.", replacing: "alice", terms: [],
                                        isEnglish: { $0 == "then" }) == "Alice, then")
    }

    /// A Term written with a mark keeps its capital: the word and the Term are compared without it.
    @Test func replacementKeepsATermWrittenWithAMark() {
        #expect(RespeakText.replacement("Jeopardy!", replacing: "jeopardy", terms: ["Jeopardy!"],
                                        isEnglish: { _ in true }) == "Jeopardy")
    }

    /// The selection's own punctuation stays around the new words: only the words change (PR #298 review).
    @Test func replacementKeepsTheSelectionsOwnPunctuation() {
        let english: (String) -> Bool = { _ in true }
        #expect(RespeakText.replacement("The.", replacing: "teh,", terms: [], isEnglish: english) == "the,")
        #expect(RespeakText.replacement("The.", replacing: "teh)", terms: [], isEnglish: english) == "the)")
        #expect(RespeakText.replacement("The.", replacing: "\"teh\"", terms: [], isEnglish: english) == "\"the\"")
        #expect(RespeakText.replacement("The.", replacing: "(teh", terms: [], isEnglish: english) == "(the")
        #expect(RespeakText.replacement("The.", replacing: " teh, ", terms: [], isEnglish: english) == " the, ")
        #expect(RespeakText.replacement("The.", replacing: "teh.\"", terms: [], isEnglish: english) == "the.\"")
    }

    /// Only Cleanup's sentence marks leave what Jake said: marks that are part of his words stay.
    @Test func replacementKeepsMarksThatArePartOfTheWords() {
        let notEnglish: (String) -> Bool = { _ in false }
        #expect(RespeakText.replacement("C#.", replacing: "c sharp", terms: [], isEnglish: notEnglish) == "C#")
        #expect(RespeakText.replacement("50%.", replacing: "fifty percent", terms: [], isEnglish: notEnglish) == "50%")
        #expect(RespeakText.replacement(".env.", replacing: "dot env", terms: [], isEnglish: notEnglish) == ".env")
        #expect(RespeakText.replacement("@jake.", replacing: "at jake", terms: [], isEnglish: notEnglish) == "@jake")
    }

    /// A mark that is part of the selected word is replaced with it, never kept beside the new words.
    @Test func replacementReplacesMarksThatArePartOfTheSelectedWord() {
        let notEnglish: (String) -> Bool = { _ in false }
        #expect(RespeakText.replacement("50%.", replacing: "100%", terms: [], isEnglish: notEnglish) == "50%")
        #expect(RespeakText.replacement("F#.", replacing: "C#", terms: [], isEnglish: notEnglish) == "F#")
        #expect(RespeakText.replacement("Java.", replacing: ".NET", terms: [], isEnglish: notEnglish) == "Java")
        #expect(RespeakText.replacement("Java.", replacing: "(.NET),", terms: [], isEnglish: notEnglish) == "(Java),")
    }

    /// A comma or colon Jake said stays; only Cleanup's closing . ! ? go.
    @Test func replacementKeepsACommaOrColonJakeSaid() {
        #expect(RespeakText.replacement("Note:", replacing: "not", terms: [], isEnglish: { _ in true }) == "note:")
        #expect(RespeakText.replacement("Well,", replacing: "will", terms: [], isEnglish: { _ in true }) == "well,")
    }
}

