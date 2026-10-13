import Foundation
import Testing
@testable import LexiconCore
import AppText
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

private func field(_ text: String, fingerprint: String? = "field-1", bundleID: String? = editor) -> FieldText {
    FieldText(text: text, selection: nil, bundleID: bundleID, fieldFingerprint: fingerprint)
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

    // MARK: HeadlessDestination's one field

    @Test func headlessReplaceReplacesASpanThatReadsExpected() async throws {
        let destination = HeadlessDestination()
        let target = try #require(await destination.target())
        _ = await destination.insert("I saw a cat.", for: DictationID(), at: target)
        let before = await destination.fieldText
        #expect(before == "I saw a cat.")

        let outcome = await destination.replace(TextSpan(location: 8, length: 3), expected: "cat", with: "dog", at: target)
        #expect(outcome == .replaced)
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

    /// "dog?" over "cat?" keeps its "?" and passes at the head only because the stub returns its
    /// input unchanged. The companion, "Dog?", is the line that is red there: it has to be lowercased
    /// to match the lowercase text it replaces.
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
}
