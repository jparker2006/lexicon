# The fn tap listens and never holds a key

Status: Proposed (`docs/DECISIONS.md` item 34). The orchestrator and the Reviewer chose it in PR #123 and Jake had a heads-up, not a question, so it stands as built until he confirms it. The question he did answer, item 59, set idle typing delay at the listen-only 2 to 12 ms as the bar M1 must keep.

Lexicon's fn tap is a listen-only CGEventTap (`.listenOnly`), created in one place, `Sources/KeyInput/EventTap.swift`, and started only when `CGPreflightListenEventAccess()` already reads true, so it never raises a permission prompt. It sees fn and every other key and swallows nothing. The spec chose one active, session-level tap, on an unmeasured "a few microseconds" callback budget from the architecture sketch. Measured live in M0 (#53, PR #123), keys reached the focused app 26 to 74 ms late through the active tap and 2 to 12 ms late through the listen-only one. A delay on every key Jake types, all day, costs more than anything a tap could swallow.

The numbers are thin: five presses were timed, and the baseline taken with the app quit was later judged not clean. They are enough to choose a direction, not to set a budget. Typing delay with Lexicon idle is the number this decision protects.

## Considered options

- **One active tap, always on** (the spec): can swallow Esc and ⌃⌘V, at the measured cost above on every key.
- **An active tap only while recording, for key-downs:** costs typing delay only between fn-down and the end of a Dictation. It is the fallback for swallowing Esc (#58) and ⌃⌘V (#62), with its per-key cost measured and written in the PR.
- **A registered hotkey** (Carbon `RegisterEventHotKey`), registered for Esc only while recording: takes the key with no tap at all. Jake chose this first for M1 (spec item 59, `docs/DECISIONS.md`); #58 tries it before anything else.

## Consequences

- `scripts/checks/21-source-lints.sh` fails on `.defaultTap` anywhere outside `Sources/KeyInput/EventTap.swift`, and its error names this ADR.
- If an active tap ever comes back, it lives in `EventTap.swift`, it is on only between fn-down and the end of the Dictation, and the token that turns it on is made inside `KeyInput`, which sits below `LexiconCore`, so no other module can leave it on.
- Any change to `EventTap.swift` gets a standing Live checks item: typing delay with Lexicon idle stays at the listen-only 2 to 12 ms. #62's own check compares against main instead ([DECISIONS item 101](../DECISIONS.md)).
- Esc during a confirmed hold or hands-free Dictation is taken by a registered hotkey (`Sources/KeyInput/RegisteredHotkey.swift`, #58), registered when the recognizer confirms the Dictation and removed when it ends; the tap still sees Esc and cancels on whichever report comes first. Live checks confirms the hotkey takes Esc; if it doesn't, the scoped active tap above replaces it.
- ⌃⌘V is taken by the same kind of registered hotkey (#62), registered when the keyboard starts and held while the app runs. Only the hotkey pastes. Its press counts as typing once, at whichever report reaches the tap thread first (the tap's copy of the key-down or the hotkey's), always before its command.
