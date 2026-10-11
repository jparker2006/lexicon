# Re-speak prototype (throwaway)

PROTOTYPE for [Re-speak fix: how it feels](https://github.com/jparker2006/lexicon/issues/23). Lives on `prototype/respeak` only. Never ship it.

One Swift file, about 330 KB built. Apple on-device speech stands in for the real speech model; Jev (TypeSafe direct, `jev-1.13.0`) picks the word. The key is read from `~/code/lexicon/.env` and never printed.

## Run

Quit Wispr Flow first (both use fn). Then `./run.sh`. Grant Accessibility, Microphone and Speech Recognition when asked. The menu bar shows `Re` once it's live (`Re ⚠︎` means Accessibility isn't granted yet). A rebuild changes the ad-hoc signature, so macOS asks for Accessibility again.

## Triggers (all live at once)

- **fn hold**: plain dictation. No word hints, so it gets tech words wrong on purpose.
- **fn + Shift hold**: say the right word, let go.
- **Right Option hold**: say the right word, let go.
- **Spoken cue**: fn hold and say "fix Supabase" or "I meant Supabase".
- **Auto-detect** (menu toggle, off by default): a 1 to 3 word fn dictation within 30 s of the last one; Jev decides whether it's a fix.
- **Your selection**: select the wrong word first, then any trigger replaces exactly that, no Jev.

## Menu knobs

- **While it decides**: pill by the cursor / pill plus the guess selected in the text / sounds only.
- **Extra delay**: 0, 300, 700, 1500 ms added before the fix lands.
- **When unsure** (Jev below 0.75): choices 1, 2, 3 and Esc / best guess anyway / change nothing.

Every step is logged with timings to `~/Library/Logs/LexiconRespeakProto.log` (menu: Open log). `RespeakProto --selftest` runs the ranking and one Jev call without UI.
