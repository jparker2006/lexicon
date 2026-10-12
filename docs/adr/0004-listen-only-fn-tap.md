# The fn tap listens and never holds a key

Status: accepted by the orchestrator and the Reviewer in PR #123; Jake had a heads-up, not a question, so it is Proposed in `docs/DECISIONS.md` (item 34) until he confirms it. His answer on item 59 already keeps idle typing delay at the listen-only figure.

Lexicon's fn tap is a listen-only CGEventTap (`.listenOnly`), created in one place, `Sources/KeyInput/EventTap.swift`, and started only when `CGPreflightListenEventAccess()` already reads true, so it never raises a permission prompt. It sees fn and every other key and swallows nothing. The spec chose one active, session-level tap, on an unmeasured "a few microseconds" callback budget from the architecture sketch. Measured live in M0 (#53, PR #123), keys reached the focused app 26 to 74 ms late through the active tap and 2 to 12 ms late through the listen-only one. A delay on every key Jake types, all day, costs more than anything a tap could swallow.

The numbers are thin: five presses were timed, and the baseline taken with the app quit was later judged not clean. They are enough to choose a direction, not to set a budget. Typing delay with Lexicon idle is the number this decision protects.

## Considered options

- **One active tap, always on** (the spec): can swallow Esc and ⌃⌘V, at the measured cost above on every key.
- **An active tap only while recording, for key-downs:** costs typing delay only between fn-down and the end of a Dictation. It is the fallback for swallowing Esc (#58) and ⌃⌘V (#62), with its per-key cost measured and written in the PR.
- **A registered hotkey** (Carbon `RegisterEventHotKey`), registered for Esc only while recording: takes the key with no tap at all. Jake chose this first for M1 (spec item 59, `docs/DECISIONS.md`); #58 tries it before anything else.

## Consequences

- `scripts/checks/21-source-lints.sh` fails on `.defaultTap` anywhere outside `Sources/KeyInput/EventTap.swift`, and its error names this ADR.
- If an active tap ever comes back, it lives in `EventTap.swift`, it is on only between fn-down and the end of the Dictation, and the token that turns it on is made inside `KeyInput`, which sits below `LexiconCore`, so no other module can leave it on.
- Any change to `EventTap.swift` gets a standing Live checks item: typing delay with Lexicon idle stays at the listen-only 2 to 12 ms.
- Esc during a recording and ⌃⌘V also reach the app in front until #58 and #62 land a way to take them.
