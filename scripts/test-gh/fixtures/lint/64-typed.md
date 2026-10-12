## Parent

#36 (Spec: Lexicon v0)

**Milestone:** M1  
**User stories:** 36, 38, 39, 41, 42  
**Test seam:** live app + headless pipeline (retry)  
**Modules:** History, LexiconUI, LexiconCore
**Needs the Live checks session for:** agent: row actions on a sample row, and the fn double-tap gesture on a row (Live items 1 and 5)

## What to build

Per row: play (AVAudioPlayer), copy, a Test set flag that pins the audio forever, and a ⋯ menu with Retry (with a model picker; local only until M2), Show versions (model, cleaned and final text) and Delete (removes text and audio). Play and Retry are greyed out on rows whose audio has aged out. Retried text is never typed: a failed Dictation that gets text from Retry becomes not inserted.

## Acceptance criteria

### Headless

- [ ] Retry produces new text in History without typing anything; a failed row moves to not inserted.
- [ ] A pinned Dictation keeps its audio past retention.
- [ ] Delete is refused while a Dictation is recording, transcribing or ready.

### Live

- [ ] Play, pin, retry, versions and delete each work on a sample row. needs: none
- [ ] The fn double-tap on a selected row runs its action, as the Live checks request's item 8 asked. needs: #58

## Open questions

## Blocked by

- #63
- #47
- #61
- #58
