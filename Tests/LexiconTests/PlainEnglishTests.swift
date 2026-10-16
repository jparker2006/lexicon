import Testing
import WordStore

// PlainEnglish.contains (#83 review): a plain English word is one the system word list never
// writes with a capital. A Re-speak keeps the capital of a name that is also a word ("Will",
// "Grace", "Mark" are all in /usr/share/dict/words capitalized), so those are not plain English.
// Reads the list every Mac has. No mic, keys or network.

@Suite struct PlainEnglishTests {

    /// "dog" is written only in lowercase in the list, so it is plain English. "Dog" lowercases
    /// first, so the capital in a Re-speak's own text does not change the answer. Passes at the head.
    @Test func aWordTheListWritesOnlyInLowercaseIsPlainEnglish() {
        #expect(PlainEnglish.contains("dog"))
        #expect(PlainEnglish.contains("Dog"))
    }

    /// The list also writes "Will", "Grace" and "Mark" with a capital, so each is a name too and
    /// keeps its capital in a Re-speak. The first line is the guard that the list is read at all:
    /// at the head the "will" line is the red one, because the lowercase word counts as English.
    @Test func aWordTheListAlsoWritesWithACapitalIsNotPlainEnglish() {
        #expect(PlainEnglish.contains("dog"))
        #expect(!PlainEnglish.contains("will"))
        #expect(!PlainEnglish.contains("grace"))
        #expect(!PlainEnglish.contains("mark"))
    }

    /// A word the list does not hold at all is not plain English. Passes at the head.
    @Test func aWordTheListDoesNotHoldIsNotPlainEnglish() {
        #expect(!PlainEnglish.contains("supabase"))
    }
}
