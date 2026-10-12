# Lexicon

Lexicon is a Mac dictation app: you speak, it types at your cursor, and it learns the words you use from every correction.

## Language

**Dictation**:
One spoken session, held or hands-free, from the audio through to the text inserted at the cursor.
_Avoid_: Recording, transcript, utterance

**Cleanup**:
Tidying a Dictation's text after the speech model and before it's typed: fillers, stutters, self-corrections, punctuation, numbers, lists and paragraphs. It never changes what you asked for.
_Avoid_: Formatting, polish, rewrite

**Fix**:
A correction to a Dictation's text. Either a Re-speak fix or a Hand fix.
_Avoid_: Edit, correction

**Re-speak fix**:
A Fix made by saying the right word again instead of typing it.
_Avoid_: Voice edit, respeak

**Hand fix**:
A Fix made by editing the inserted text yourself.
_Avoid_: Manual edit

**Rule**:
A learned "when you hear X, write Y", added by the user or learned from a Fix the user confirmed.
_Avoid_: Replacement, correction, mapping

**Term**:
A word or name in the Lexicon that is always written one exact way, such as a product name, a person's name or a code term.
_Avoid_: Keyword, keyterm, vocabulary word, custom word

**Lexicon**:
The user's personal word store: their Terms and Rules.
_Avoid_: Dictionary, vocabulary, word list

**Test set**:
The user's recorded Dictations paired with the text they should have produced.
_Avoid_: Eval set, benchmark, dataset

**Private mode**:
A mode in which nothing leaves the Mac.
_Avoid_: Offline mode, local mode

**History**:
The saved record of every Dictation, its text versions and audio, shown in the History window.
_Avoid_: Log, archive, transcripts

**Retry**:
Hearing a saved Dictation's audio again from History, with a model picked from a list, to replace its text. Retried text is never typed.
_Avoid_: Re-run, re-transcribe, redo

**Test set pin**:
A flag on a Dictation in History that adds it to the Test set and keeps its audio forever.
_Avoid_: Star, favorite, bookmark

**Secret guard**:
A check on the Mac that keeps keys, tokens and passwords out of every text call and cuts the speech stream once one is heard. Audio already streamed can't be recalled.
_Avoid_: Redaction, filter

**Missed paste**:
A paste no app reads within 1 s. The Dictation is marked not inserted and waits for paste-last; its text stays on the clipboard until 2 s after the write, so a late Cmd-V still pastes it, then the user's own clipboard comes back.
_Avoid_: Failed paste, dropped text

**Structural check**:
The check in code that AI cleanup's output kept the meaning of the rules-only text: no content word added or dropped, negations and numbers intact. Failing it types the rules-only text.
_Avoid_: verify(), meaning check

**verify()**:
The research's earlier meaning check, "output equals the raw text minus listed fillers". Replaced by the structural check, which allows AI cleanup. Only old research uses the word.
_Avoid_: Using it for the structural check

**Jev**:
TypeSafe's decision model, called directly with one pinned version, that picks the right candidate for a Re-speak fix or a Hand fix. Every call has a local fallback, and no call happens during plain dictation.
_Avoid_: The LLM, the AI

**Hook**:
A command one program runs when something happens in another. In these docs it means a Claude Code hook, such as the guard hook that refuses unsafe agent commands, or a test hook, a debug-only command the harness sends Lexicon Dev. Lexicon itself has no product hooks unless the after-M1 grill brings them back.
_Avoid_: Plugin, callback, trigger
