# Lexicon v0 architecture

Decided in [App architecture and stack](https://github.com/jparker2006/lexicon/issues/17) (2026-10-10) with `/pstack:architect`. The type sketch, a SwiftPM package of empty bodies that compiles, is on the [`architecture/app-stack`](https://github.com/jparker2006/lexicon/tree/architecture/app-stack) branch and is the M0 starting skeleton. Words follow [GLOSSARY.md](../GLOSSARY.md). Records: [ADR 0001 one process](adr/0001-one-process.md), [ADR 0002 AppKit only](adr/0002-appkit-only.md), [ADR 0003 Command Line Tools only](adr/0003-command-line-tools-only.md). Brought up to [Spec: Lexicon v0](https://github.com/jparker2006/lexicon/issues/36) and its supersessions list; where this doc and the spec disagree, the spec wins.

## Decisions in one screen

| Question | Decision |
|---|---|
| Processes | One AppKit menu bar app (`LSUIElement`, `SMAppService.mainApp` login item). Plus dev-only `lexicon-eval` (the scorer's headless pipeline) and `lexicon-harness` (live-app checks; it runs a target text field as its own child process). No XPC, no helper agent. A `lexicon` hook CLI in the bundle is built only if the after-M1 grill wants hooks. |
| UI | AppKit for every surface. SwiftUI is never imported. |
| Toolchain | Command Line Tools 26.6, SwiftPM only, `scripts/bundle.sh` assembles and signs `Lexicon.app` with the self-signed "Lexicon Dev" certificate. No Xcode, no XcodeGen. |
| Platform | macOS 26 and up. Swift 6 language mode, strict concurrency. |
| Dependencies | FluidAudio only, and only in `LocalParakeet`. Any other package needs Jake's sign-off. |
| Data | `~/Library/Application Support/Lexicon/` for the daily app, `Lexicon Dev/` for builder builds (separate bundle ID). The dev model folder is a symlink to the daily one. |
| fn | Hold 0.30 s or more for push-to-talk; second fn-down within 0.25 s of the first fn-up for hands-free. fn only: no Fn+Space, no fallback hotkey. |
| Speech | M0 and M1: local Parakeet only. From M2, Meta Muse streams while Jake talks and races local; the cloud wins if its final text arrives within 300 ms after recording stops; after that, the first engine to finish wins. |
| Cleanup | Rules-only until M3. Then AI cleanup with a structural check and a deadline of about 450 ms after the speech final, falling back to rules-only text. Private mode and offline are rules only. |
| Current repo | The repo under `~/code` with the most recent file change (not counting `.git`), from FSEvents; at launch, a week of FSEvents history picks it. No hooks. |
| Inbox | The app watches `<data>/inbox/` for JSON messages (hook prompts, only if hooks come back). Prompts older than 60 s are dropped. |
| Test hooks | Debug builds only (`#if DEBUG`; `scripts/bundle.sh` fails a release binary that has them), on for the dev bundle ID launched with `--test-hooks`. `lexicon-harness` writes a request under `<data>/test-hooks/requests/` and reads the reply from `replies/`, and reads the app's status item, windows and a target text field through Accessibility. Only the live-app lane's holder, the Live checks session, runs it (`scripts/live-lane.sh`). |
| Local model | Loaded on fn-down when not resident, unloaded after 10 idle minutes; always loaded while Private mode is on or, with a cloud model set, the network is down. |
| Lifecycle owner | One `Conductor` actor decides what happens to every Dictation. Each piece of state has one other owner. |

## Problem

One Dictation touches nine kinds of knowledge (keys, audio, sockets, the local model, Cleanup, Rules, other apps' text, storage, UI) on four kinds of thread. If every module owns a slice of the Dictation, its status has no owner; if one object owns everything, eight parallel builders collide in it. Several decided rules are "never" rules: never lose audio, never type recovered text, never call the cloud in Private mode, never wait on Jev before insert. A builder who didn't read the doc breaks those unless the types make breaking them impossible. The same pipeline also has to run headless on a WAV for the scorer (#15) and be driven by test hooks (#14). Prompts from a hook process (#13) come only if the after-M1 grill brings hooks back.

## Usage (caller's view)

The app shell is the only composition:

```swift
let paths = AppPaths.forBundle(id: bundleID)                 // "Lexicon" or "Lexicon Dev"
let system = try LexiconSystem.live(paths: paths, bundleID: bundleID,
                                    local: ParakeetTranscriber(paths: paths))  // the fn tap starts first
Task.detached { await system.run() }                         // key loop, recovery, mic prepare, model warm-up
indicator.follow(await system.conductor.events(), levels: system.recorder.levels)  // pill, icon, sounds
```

One Dictation, in `LexiconCore/Conductor+Run.swift` (abridged; this file is the trace):

```swift
let capture  = try await recorder.start(start.input, writingTo: history.audioURL(for: id))   // audio first
history.record(.began(id, origin: start.origin, purpose: start.purpose, at: Date(), app: context))
let words    = await lexicon.forDictation(in: context)                  // up to 50 Terms for speech, 200 for Cleanup, plus Rules
let attempt  = await speech.begin(feed: capture.feed, plan: speechPlan)  // from M2, the cloud socket opens while Jake talks
let cleaning = cleanup.begin(plan: cleanupPlan, segments: attempt.segments)   // cleans finished sentences
// fn-up:
let take     = await capture.stop(.released(at: releasedAt))            // adaptive tail: stop on silence, cap 200 ms
let outcome  = await attempt.finish(take.clip)                          // finalize + local race + 300 ms cutoff
// land(outcome, run):
let cleaned  = await run.cleaning.finish(modelText: heard.text, deadline: run.cleanupDeadline)
history.record(.textReady(id, cleaned.versions, cleanup: cleaned.outcome, model: heard.model, typing: typing))
let delivery = await destination.insert(cleaned.versions.cleaned, for: id, at: target)  // InsertGuard first
history.record(.delivered(id, receipt, lag: lag))                       // or .notInserted(id, reason)
```

The scorer runs the same Conductor with a recording destination: `HeadlessSystem.make(...).conductor.dictate(file:pace:)`. If the after-M1 grill brings hooks back, the hook would be one line in Claude Code settings: `~/Applications/Lexicon.app/Contents/Helpers/lexicon hook claude-code`.

## Shape

### Modules

Each SwiftPM target is one module, and its dependency list is its "may import" list. Every build passes `--explicit-target-dependency-import-check error`, and `scripts/check-imports.swift` fails the build on the transitive imports that flag misses, and on any import of a sole-owner system module from the wrong place (SwiftUI and Combine: nowhere). Every import is internal unless written `public import` (`InternalImportsByDefault`), so storage and wire types can't leak through a public signature.

| Module | Owns | May import |
|---|---|---|
| `LexiconDomain` | Shared values only (plus `RuleSet` matching, which WordStore compiles and Cleanup runs): `DictationID`, `DictationStatus` (with `canMove`, `isInFlight`, `needsAudio`), `TextVersions`, `SpeechSegment`, `InsertionReceipt`, `Term`/`Rule`/`RuleSet`, `Preferences`, `CloudAccess`, `AppPaths` (root only), `AccessibilityID` (identifiers the harness finds the UI by) | Foundation |
| `SQLiteKit` | One connection to system SQLite, WAL, migrations | SQLite3 |
| `KeyInput` | Event tap thread, `FnGesture`, hotkeys, `InputClock` (single writer) | Domain |
| `AudioCapture` | Engine, sink node, ring, converter, CAF writer, `F_FULLFSYNC` every 1 s and at stop, device rebuild, adaptive tail | Domain |
| `Transcription` | One adapter file per cloud provider (Muse from M2), sockets, keywords, finalize, local race, residency, reachability. No reconnect after a cloud failure: local is already racing, and with no local model the Dictation waits and is transcribed again when the network returns. `CloudLink` (adapter, socket, network path) is the one seam tests replace, with a scripted fake provider | Domain |
| `LocalParakeet` | The FluidAudio adapter (Parakeet Unified; Ultra or v3 as the multilingual pick), model install and compile. No word boosting; Rules in code instead. The only FluidAudio importer | Domain, Transcription |
| `Cleanup` | Rules, the AI cleanup stage (OpenRouter, from M3), the structural check, the rules-only fallback | Domain |
| `WordStore` | The Lexicon: Terms, Rules, folding, `lexicon.sqlite`, per-Dictation selection. `CodeTerms`: code Terms (names only) and the current repo, scanned at launch and followed with FSEvents on `~/code` and the skill folders | Domain, SQLiteKit |
| `History` | Every durable fact about a Dictation: `history.sqlite`, `audio/`, recovery, retention, the window's reader | Domain, SQLiteKit, AudioCapture |
| `AppText` | Everything done to other apps' text: focus capture, `InsertGuard`, paste and restore, read, watch, replace | Domain, KeyInput |
| `Jev` | TypeSafe direct calls, `jev-1.13.0` pinned, one request per state with all its questions, for Re-speak and Hand fixes only; every call carries a local fallback | Domain |
| `Fixes` | Re-speak resolution and saving each Re-speak fix to the Test set; Hand fix watching and any Rules learned from Fixes, as the after-M1 grill decides | Domain, History, WordStore, AppText, Jev |
| `Inbox` | Inbox file format, writer, watcher | Domain |
| `TestHooks` | Debug builds only: the test-hook commands and replies, the harness's sender and the app's server | Domain |
| `LexiconCore` | `Conductor`, `LexiconSystem`, `HeadlessSystem`, `PreferencesStore`, Keychain | all above except LocalParakeet |
| `LexiconUI` | Status item, indicator pill and sounds, first-run setup, start at login and the warning dot, History window, Lexicon page, Settings, Re-speak pill | Domain, History, WordStore, AudioCapture, Fixes, Core |
| `LexiconApp`, `lexicon`, `lexicon-eval`, `lexicon-harness` | App shell; hook CLI only if the after-M1 grill wants hooks (Domain and Inbox only, about 300 KB); scorer; the live-app harness (dev only, `scripts/harness.sh`) | as declared |

### Who owns what

- **The Conductor** decides the order of events for every Dictation and holds no durable state. It owns one live capture slot (one mic), the tasks of Dictations past fn-up, and the insert order: fn never waits, so a new Dictation can start while the last one finishes (its tail is cut), and Dictations insert in the order they were spoken. A waiting Dictation gives up its turn. Esc still transcribes and saves the Dictation, untyped, for paste-last ([fn and recording behavior](https://github.com/jparker2006/lexicon/issues/18)).
- **History** owns rows. Callers describe events (`.began`, `.audioEnded`, `.textReady`, `.delivered`, `.notInserted`, `.fixRecorded`, `.deleted`). One `apply` switch holds every row rule. A status move applies only when `canMove(to:)` allows it from the stored status, so a replayed or racing event is a no-op. A Dictation about to be typed sits in `ready` (text saved, paste in progress) until the paste's real outcome moves it to `inserted` or `notInserted`. Only History holds the final text (cleaned text plus Fixes).
- **The open `LiveCapture`** owns audio bytes until stop (`~Copyable`, stopped exactly once). After stop, the file belongs to History.
- **AppText** owns live Accessibility references, keyed by `DictationID`. The durable `InsertionReceipt` (app, field fingerprint, caret, short context) is stored by History.
- **`FnGesture`** owns gesture state on the tap thread. The Conductor asks it to end and never writes it.
- **`PreferencesStore`** owns settings. The Conductor snapshots them once at fn-down, so a mid-Dictation change never affects the Dictation in flight.

### Invariants the compiler enforces

- Recovered and retried text is never typed: `TextDestination.Target` has no public initializer, and only a live fn-up or a test file run produces one.
- `CloudAccess` is the only door to the network: speech, Cleanup's LLM, Jev and model downloads all take one. Its only constructor returns nil in Private mode or for an always-private app, and Cleanup withholds it when "AI cleanup" is off.
- Every Jev call has a local fallback: `decide(_:access:budget:fallback:)` has no other form.
- A capture is stopped, and an attempt finished, at most once: both are `~Copyable` with `consuming` methods.
- One list each, compiler-checked: providers, statuses (index predicates and retention derive from the enum), key commands, inbox messages, History events.
- The late-text rule runs on every insert: `InsertGuard.decide` is a pure function with no grace window.
- Text is never typed twice: a row left in `ready` after a crash becomes `notInserted` (reason `interrupted`) at launch; paste-last still reaches it.

### One push-to-talk Dictation

1. fn-down. The tap callback (`KeyInput/EventTap.swift`) feeds `FnGesture` (hold 0.30 s, second fn-down within 0.25 s of the first fn-up, 20-minute cap), which yields `.dictationBegan`. fn passes through.
2. The Conductor starts the capture first (`AudioCapture/Recorder.swift`), so audio is in the page cache before anything else can fail. Then it records `.began` (the row exists from the start), takes the Lexicon Terms, opens the cloud speech socket from M2 (TLS overlaps speech), starts a `CleanupSession` on the attempt's finished segments, loads the local model if it isn't resident, and starts a `beginActivity(.userInitiated, .latencyCritical)` so App Nap can't slow the Dictation.
3. While Jake talks: from M2, chunks stream to the cloud provider; finished sentences go through Rules and, from M3, AI cleanup as they arrive.
4. fn-up. In parallel: AppText captures the target field and an input mark and reads Jake's clipboard ahead of the paste; the capture keeps the adaptive tail (stop on silence, cap 200 ms).
5. `attempt.finish` sends finalize and races local. The deadline runs from recording stopping (the start of `finish`): the cloud final wins if it arrives within 300 ms of that, and after that the first engine to finish wins. A cloud that cannot run hands over to local at once: no key, network down at fn-down, a connect, socket or provider error, access revoked, or the Secret guard on a finalized segment. With no local text, the cloud gets at most 10 s, then the Dictation waits for the network (or for local, if it is still running). Private mode gets no cloud at all. In M0 and M1 there is no cloud, so local text is the outcome.
6. `cleanup.finish` cleans the last sentence (and may revise the one before), runs the structural check against the Rules output, and returns the AI cleanup text or the rules-only text with the reason. The Cleanup deadline starts at about 450 ms after the speech final, tuned on the Test set so total lag stays within the pass mark; a miss types the rules-only text. Until M3, Cleanup is rules only.
7. `.textReady` is queued for History (status `ready`), then `InsertGuard.decide` checks same app, same field, no input since the mark (where an app's field can't be detected reliably: same app and under 5 s), and AppText pastes (pasteboard promise, Cmd-V). The target's read of the promise is the receipt: no read within 1 s means not inserted (the text stays up until 2 s, so a late Cmd-V pastes it, never Jake's old clipboard). If Jake denies Lexicon "Paste from Other Apps", a Dictation is not pasted and waits for paste-last; ⌃⌘V, which he asks for, still pastes, without restoring his clipboard. Text that fails the check, or has nowhere to go, is not typed: it waits in History for paste-last, with a notice. The clipboard restore, fsync, the `.delivered` write, Fix watching and Jev all run after, off the path.

### Concurrency

| Where | Runs |
|---|---|
| Core Audio IO thread | Sink block: memcpy into the SPSC ring, nothing else |
| Audio writer queue | Drain, convert to 16 kHz, write CAF, `F_FULLFSYNC` each 1 s and at stop, yield chunks |
| Event tap thread (own run loop) | Tap callback in microseconds, `FnGesture`, `InputClock` |
| AX thread (own run loop, custom executor) | `TargetApp`: Accessibility calls with timeouts, observers, Cmd-V |
| Main actor | AppKit, the History window's read-only connection, pasteboard promise callbacks |
| `Conductor` actor | Lifecycle decisions, never queued behind UI |
| Speech and Cleanup actors, URLSession | Sockets, the race, LLM calls |
| History writer queue | Every `history.sqlite` write, FIFO, never awaited on the hot path |
| `LocalTranscriber` | One job at a time; live work preempts recovery and retry |

### Privacy (from [Private mode, keys, and what leaves the Mac](https://github.com/jparker2006/lexicon/issues/5))

- One `CloudAccess` per Dictation, granted at fn-down once the active app is known. Turning Private mode on, or focus moving into an always-private app, revokes it mid-Dictation: every key lookup returns nil, the speech stream is cut at once, and the local model, already racing, finishes the text.
- The Secret guard is a pure check in `LexiconDomain`. Calls that send text get their key through `access.key(_:sending:)`, which runs the guard first; a match revokes access for the rest of the Dictation. Transcription also checks each finalized segment, so a secret spoken early cuts the rest of the stream, and a caught segment never reaches Cleanup. A Term the guard flags is left out of the speech session's keywords. Limit: audio streams while Jake talks, so a spoken secret has already reached the speech provider before any text exists. The guard protects text calls and later audio, not audio already sent; Private mode is the answer for that.
- The most each service sees in normal mode: Meta Muse gets the audio plus up to 50 Lexicon words; the cleanup model gets the Dictation text plus up to 200 (OpenRouter with `zdr: true`); Jev gets only the few words around a Re-speak or Hand fix target plus candidates. In Private mode and offline: local Parakeet, rules-only Cleanup, Re-speak by sound matching alone, Hand fixes without Jev. No on-device LLM for now (Apple Foundation Models doesn't qualify).
- fn-down while macOS secure input is on (a password field) starts nothing.
- No analytics or crash reporting; Dictation text and keys are never logged. Keys are read from the Keychain once and kept in memory.

### Data

- `history.sqlite`: `dictation` (status, origin, model, cleaned and final text, speech model, lag, Cleanup outcome, audio state, pin), `attempt` (every engine try), `fix`, `insertion` (receipts). Enum columns store Swift raw values; partial indexes are generated from `DictationStatus`.
- `audio/<id>.caf`: 16 kHz mono 16-bit, kept a rolling 14 days or 1 GB (whichever first), never deleted while a Dictation needs it, pinned audio kept forever.
- `lexicon.sqlite`: Terms and Rules (each Rule with a source field: added or learned), owned by WordStore. Code Terms are held in memory, not stored.
- `models/`: Parakeet weights (about 609 MB), never in the bundle.
- `inbox/`: hook messages, only if hooks come back.
- `test-hooks/`: dev builds only, the harness's requests and the app's replies.
- Keychain: one item per cloud credential (Meta, OpenRouter, TypeSafe), service = bundle ID. `lexicon-eval` reads environment variables instead.
- UserDefaults: one `Preferences` value, owned by `PreferencesStore`.

### Budgets

| Budget | Target |
|---|---|
| App binary | 4 MB or less without FluidAudio; bundle 12 MB or less with it, weights outside |
| Idle memory, model unloaded | 30 MB or less (a bare AppKit status item measured 11.3 MiB) |
| While dictating, model loaded | about 160 MB |
| Launch to fn working | 150 ms or less |
| History window, click to first rows | 100 ms or less at p95 (AppKit measured 52 ms cold) |
| fn-down to first audio | 60 ms or less, logged per Dictation |
| Lexicon's own work, fn-up to Cmd-V | 10 ms or less |
| fn-up to text on screen | p50 700 ms or less, p95 1 s or less (the lag part of the pass mark) |
| Jev call (Re-speak) | 250 ms, then the fallback decides: measured warm p95 215 ms, inside the 0.5 s release-to-fix target with the speech final and the replace |
| fn-up to text, p95 ceiling | adaptive tail (up to 200 ms) + cloud cutoff (300 ms after recording stops) + Cleanup deadline (about 450 ms) + 10 ms = about 960 ms |

The p95 ceiling sits inside 1 s, against Wispr's own logged lag on Jake's Mac (p50 740 ms, p95 1,671 ms). It assumes the local text is ready by the cloud cutoff (local Parakeet measured about 80 ms for clips of 6 s or less; long hands-free Dictations are an M0 measurement) and that paste itself is fast (about 12 ms in a native field; slow apps unmeasured), so the margin is thin. The p50 estimate, roughly 500 to 550 ms, is an assumption until M0 and M2 measure it.

### How M0 to M5 land

| Milestone | Fills | Seams already there |
|---|---|---|
| M0 It types (local model) | First the early build tickets (Glox workflow, pstack, this doc). Then the never-lose spine headless (file input, CAF writer, History `began`/`audioEnded`/`textReady`/recovery, `Conductor.dictate(file:)` on a WAV with a scripted fake engine), then the mic, `FnGesture` (hold), `LocalParakeet` (install, residency), rules-only Cleanup, paste and restore, status item, indicator pill and sounds, first-run onboarding, start at login, the bundle and dev-run scripts, `lexicon-eval`. In parallel once `lexicon-eval` exists: Test set gold, the review page and the weekly export script | WordStore returns empty; Cleanup is rules only; `SpeechPlan` is local only |
| M1 Never loses it | Hands-free double-tap, Esc, chord cancel, 20-minute cap and warning, crash recovery, retention, History window (search, copy, play, pin, retry with picker, show versions, delete), paste-last, the late-text rule and notices, the waiting path | Row at start and CAF from M0; `land` already has the waiting branch, retried when the network returns or a local model becomes available |
| M2 Cloud and Private mode | The Muse adapter, the 300 ms race, Keychain keys, the Settings window, Private mode (toggle, always-private apps, outlined logo, hard kill, survives restart, mid-Dictation revoke), the Secret guard, network-loss behavior, the model picker | `CloudAccess` gates every cloud call already; local already produces the text |
| M3 Good enough to swap | AI cleanup with the structural check and deadline; WordStore (Terms, Rules, folding, code Terms, selection), the Lexicon page and Import (load the starter Lexicon); current repo from the most recently changed folder; bake-off adapters (Cartesia, MAI, a mature backup) and the speech and cleanup bake-offs; the head-to-head run on the held-back 100 | One adapter file per provider; `CleanupModel` seam |
| M4 Fix by voice | The fn+Shift trigger, candidate ranking, Jev choice with fallback, the select-first path, the "fix X" backup, the cursor pill and choices, `TargetApp.replace` and terminal paths, Re-speak fixes saved to the Test set. No Jev for close calls | `DictationPurpose.respeak` and `InsertionReceipt` exist from day one |
| M5 Learns from you | Designed in the after-M1 grill: Hand fix (when and how Lexicon asks, #24), when a Fix becomes a Rule and how Rules are undone, light app formatting; the `lexicon` hook CLI only if the grill brings hooks back | Every insert stores a receipt; `fixes.didInsert` runs after every insert; Fix rows in History; Rules have a source field and reach Cleanup through the fn-down snapshot; the inbox exists |

## Synthesis decision

Four models designed Lexicon independently against the same brief (`/pstack:arena`): Opus and Fable free, Sonnet forced to argue for multiple processes, Haiku forced to use the fewest pieces. A blind Fable judge scored them on six criteria (bar on the hot path, fast and small, safe for agent builders, interface depth, M0 to M5 without redesign, testability): Opus 29 of 30, Fable 20, Sonnet 19, Haiku 17. The judge and the orchestrating session independently picked the Opus design as the base, because its invariants are compile-time, its hot path starts capture before anything can fail and keeps every durable write off the fn-up path, and its sketch contradicted none of its own claims. Three of four candidates converged on one process and all four on AppKit, before the measurements agreed.

Grafted in:

- From Fable: a stream of finished speech segments, the shape of the Cleanup stage (a session fed while Jake talks, finishing to a checked result with a reason), and the persisted insertion receipt.
- From Sonnet: the late-text rule as a pure `InsertGuard.decide`, status rules derived from the enum, the import check (made derived, not hand-listed), and holding a latency-critical activity during a Dictation.
- From Haiku: guarded status transitions in History, the launchd launch guard, and live work preempting background work on the local model.
- From the judge's red flags on the base: one value instead of a 12-parameter `land`, `TextVersions.final` no longer publicly writable, and no hand-listed statuses.

Rejected: Sonnet's three-process split (see ADR 0001); always-resident local model (Fable, Haiku); Fable's 1.5 s grace window on the late-text check (a quick app switch would paste into the wrong app); Fable's `Settings` threaded through every module; deleting audio on cancel; Sonnet's SwiftUI settings window (measured: the SwiftUI runtime stays loaded after close).

## Tradeoffs accepted

- We accept 15 library modules and a longer `Package.swift` in exchange for boundaries the build enforces for eight parallel builders.
- We accept AppKit's extra code in exchange for one framework and the measured speed and memory.
- We accept a generic `Conductor<Destination>` in exchange for "recovered text is never typed" being a type error, and for the scorer running the real lifecycle.
- We accept `~Copyable` captures and attempts (builders must learn `consuming`) in exchange for "stopped exactly once" without runtime flags.
- We accept fire-and-forget History writes in exchange for an fn-up path that never waits on SQLite. The audio file is the truth, so recovery re-transcribes and never re-types.
- We accept at-most-once inbox delivery: if hooks come back, a lost hook prompt is a missed Hand fix, never a lost Dictation.
- We accept a 0.4 to 0.6 s local model load on the first Dictation after 10 idle minutes, in exchange for about 130 MB less memory most of the day.

## Alternatives considered

- **Three processes** (always-on agent for tap, capture and disk; UI and speech app; on-demand model service). Strongest isolation, but it buys nothing the audio file doesn't already guarantee, and it costs a second code identity, a Login Items approval, IPC on the text path and Xcode bundling.
- **SwiftUI first** (`MenuBarExtra`, SwiftUI windows). Less code per window, but no non-activating panel and no status item button control, so AppKit is needed anyway; measured slower and heavier.
- **A pipeline of stage actors** (capture, transcribe, clean, insert, store). This is temporal decomposition: status and "what next" spread across five modules, and waiting, retry and recovery each need their own wiring.
- **One module.** Simplest start, but nothing stops a builder reaching into SQL, Accessibility references or gesture state.

## Implementation reconciliation

Builders record accepted deviations here, with who accepted them, and update the usage, signatures and ownership above before the next unit starts. Architect's scrap rule applies: if the same workaround shows up across unrelated code, if types need escape hatches (`@unchecked Sendable`, casts, always-set optionals), or if two independent deviations share a shape, stop and re-run `/pstack:architect` instead of bolting fixes on.

- **The live wiring** ([#56](https://github.com/jparker2006/lexicon/issues/56), proposed by its builder, for the Reviewer to accept). `main.swift` calls `AppDelegate.startSystem` before AppKit: `LexiconSystem.live` starts the tap, then opens History, the Lexicon and `TargetApp` (one `InputClock` for the tap and `TargetApp`), and `system.run()` starts the key loop off the main thread, so fn works while AppKit launches. The app shell composes the status item, the indicator and History itself; `AppUI` stays a stub until Settings needs it. Not wired until their tickets: Fixes and Jev (Jev never runs during plain dictation), the inbox and code Terms (no model takes Terms before M2). `run()` starts crash recovery beside the key loop, never in front of it.
- **Every key command names its Dictation** ([#56](https://github.com/jparker2006/lexicon/issues/56)). fn-down mints the `DictationID`, and confirm, stop, cancel and discard carry it, so the Conductor ends only the capture a command names. Sleep goes through the recognizer as a release, on the same ordered stream; nothing resets the gesture from outside.
- **fn-up waits at most 2 s for a model load** ([#56](https://github.com/jparker2006/lexicon/issues/56), proposed by its builder, for the Reviewer to accept). The app loads the local model at launch. If a Dictation's fn-down load is still running 2 s after fn-up (the first load of a new build compiles for about 25 s), the Dictation goes waiting (`localModelLoading`) instead of holding Jake at the cursor.
- **The Lexicon page edits the one Lexicon actor** ([#71](https://github.com/jparker2006/lexicon/issues/71), proposed by its builder, for the Reviewer to accept). `LexiconUI` imports `WordStore`, as it imports `History` for the History window's reader, and `LexiconWindowPresenter` takes a `Lexicon`: the same actor the Conductor reads at fn-down, so an edit reaches the next Dictation. The app shell hands it `LexiconSystem.lexicon`, the system's only one: two `Lexicon` actors on one file would leave a Dictation blind to the page's edits until relaunch. `lexicon-eval --lexicon <file>` imports a Lexicon file into each Dictation's own temporary Lexicon, through `HeadlessSystem.lexicon`.
- **First-run setup lives in LexiconUI** ([#57](https://github.com/jparker2006/lexicon/issues/57), proposed by its builder, for the Reviewer to accept). `Setup` reads both permissions, the model and the globe key into one pure `SetupFacts`, which decides the next step, the warning dot and whether the window opens at launch (first run is a Microphone answer still undetermined or no model, so no saved flag). What only the shell imports (the fn tap's state and `GlobeKey` in KeyInput, the model files and install in LocalParakeet, the mic) reaches it as `Setup.Services` closures, so LexiconUI's dependency list is unchanged; #53's stopgap permission lines in `LexiconApp/Permissions.swift` are gone. Granting Accessibility relaunches the app (a new instance through LaunchServices, so launchd is its parent, then the old one quits), once per launch that began untrusted, with `--continue-setup` so the window carries on. While the dot shows, a left click on the menu bar icon opens that step; a right click opens the menu, and an Accessibility press (the harness) still opens the menu.
- **Model downloads end when Private mode turns on** ([#57](https://github.com/jparker2006/lexicon/issues/57)). `PreferencesStore.downloading` grants a `CloudAccess` for one download and revokes it the moment Private mode turns on; `CloudAccess.untilRevoked` races the download against the revoke and cancels it (FluidAudio's downloader honors cancellation). A model counts as installed only when whole: a compiled model's `coremldata.bin` and no `.partial` file, FluidAudio's own test.
- **Only the daily copy starts at login unasked** ([#57](https://github.com/jparker2006/lexicon/issues/57), proposed by its builder, for the Reviewer to accept). `SMAppService.mainApp` is registered on first run for the daily bundle id only: a dev build registered too would start beside the daily copy after every login, two apps on one fn key. Lexicon Dev's menu toggle still turns it on for a live check. A login item Jake turned off in System Settings (`requiresApproval`) is never registered over.
- **The fn tap is listen-only in M0** ([#53](https://github.com/jparker2006/lexicon/issues/53), proposed by its builder, for the Reviewer to accept). The spec says one active tap. Measured live, keys reached apps 26 to 74 ms after they were pressed with an active tap and 2 to 12 ms with listen-only, and M0 swallows nothing. The tap starts only when `CGPreflightListenEventAccess()` is already true (it reads true with Accessibility alone, Input Monitoring unlisted), so it never raises a prompt. M1's Esc needs swallowing: an active tap for key-downs, enabled only while recording.

## Hand-offs

All settled by [Spec: Lexicon v0](https://github.com/jparker2006/lexicon/issues/36):

- [Speech pipeline](https://github.com/jparker2006/lexicon/issues/19): the lag sum is in Budgets above; the tail is adaptive (stop on silence, cap 200 ms); no spare pre-opened speech connection (Meta closes idle streams), revisited only if History shows cold connections costing real lag.
- [Hand fix](https://github.com/jparker2006/lexicon/issues/24): no hooks for now; who installs any hook config waits for the after-M1 grill, and only if it brings hooks back.
- [Private mode, keys, and what leaves the Mac](https://github.com/jparker2006/lexicon/issues/5) (closed): the Secret guard can't recall audio already streamed, an accepted limit. Once a local model exists, losing the network goes local with nothing queued. The waiting branch is only for when no engine can produce text (for example the local model isn't installed yet), retried when the network returns or a local model becomes available.

## Next implementation step

After the early build tickets (Glox workflow, pstack, this doc update), build the never-lose spine headless first: `AudioCapture`'s file input and CAF writer, History's `began`/`audioEnded`/`textReady`/recovery, and `Conductor.dictate(file:)` with the headless destination and a scripted fake engine, proven by a Swift Testing test on a short 16 kHz WAV. Then add the mic, the fn key and local Parakeet.
