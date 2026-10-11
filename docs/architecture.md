# Lexicon v0 architecture

Decided in [App architecture and stack](https://github.com/jparker2006/lexicon/issues/17) (2026-10-10) with `/pstack:architect`. The type sketch, a SwiftPM package of empty bodies that compiles, is on the [`architecture/app-stack`](https://github.com/jparker2006/lexicon/tree/architecture/app-stack) branch and is the M0 starting skeleton. Words follow [GLOSSARY.md](../GLOSSARY.md). Records: [ADR 0001 one process](adr/0001-one-process.md), [ADR 0002 AppKit only](adr/0002-appkit-only.md), [ADR 0003 Command Line Tools only](adr/0003-command-line-tools-only.md).

## Decisions in one screen

| Question | Decision |
|---|---|
| Processes | One AppKit menu bar app (`LSUIElement`, `SMAppService.mainApp` login item). Plus `lexicon` (in the bundle, run by the Claude Code and Codex hooks) and `lexicon-eval` (dev only, the scorer's headless pipeline). No XPC, no helper agent. |
| UI | AppKit for every surface. SwiftUI is never imported. |
| Toolchain | Command Line Tools 26.6, SwiftPM only, `scripts/bundle.sh` assembles and signs `Lexicon.app` with a stable self-signed certificate. No Xcode, no XcodeGen. |
| Platform | macOS 26 and up. Swift 6 language mode, strict concurrency. |
| Dependencies | FluidAudio only, and only in `LocalParakeet`. Any other package needs Jake's sign-off. |
| Data | `~/Library/Application Support/Lexicon/` for the daily app, `Lexicon Dev/` for builder builds (separate bundle ID). The dev model folder is a symlink to the daily one. |
| Hook channel | `lexicon` writes a JSON file into `<data>/inbox/`; the app watches the folder. Prompts older than 60 s are dropped. |
| Local model | Loaded on fn-down when not resident, unloaded after 10 idle minutes; always loaded while Private mode is on or the network is down. |
| Lifecycle owner | One `Conductor` actor decides what happens to every Dictation. Each piece of state has one other owner. |

## Problem

One Dictation touches nine kinds of knowledge (keys, audio, sockets, the local model, Cleanup, Rules, other apps' text, storage, UI) on four kinds of thread. If every module owns a slice of the Dictation, its status has no owner; if one object owns everything, eight parallel builders collide in it. Several decided rules are "never" rules: never lose audio, never type recovered text, never call the cloud in Private mode, never wait on Jev before insert. A builder who didn't read the doc breaks those unless the types make breaking them impossible. The same pipeline also has to run headless on a WAV for the scorer (#15), be driven by test hooks (#14), and accept prompts from a hook process (#13).

## Usage (caller's view)

The app shell is the only composition:

```swift
let paths = AppPaths.forBundle(id: bundleID)                 // "Lexicon" or "Lexicon Dev"
let system = try LexiconSystem.live(paths: paths, bundleID: bundleID,
                                    local: ParakeetTranscriber(paths: paths), prompter: prompter,
                                    testHooks: isDevBuild && args.contains("--test-hooks"))
AppUI(system: system, prompter: prompter).start()            // status item + hidden indicator panel
Task { await system.run() }                                  // recovery, key loop, inbox loop, mic prepare
```

One Dictation, in `LexiconCore/Conductor+Run.swift` (abridged; this file is the trace):

```swift
let capture  = try await recorder.start(start.input, writingTo: history.audioURL(for: id))   // audio first
history.record(.began(id, origin: start.origin, purpose: start.purpose, at: Date(), app: context))
let words    = await lexicon.forDictation(in: context)                  // 50-100 terms + Rules, in memory
let attempt  = await speech.begin(feed: capture.feed, plan: speechPlan)  // socket opens while Jake talks
let cleaning = cleanup.begin(plan: cleanupPlan, segments: attempt.segments)   // cleans finished sentences
// fn-up:
let take     = await capture.stop(.released(at: releasedAt))            // adaptive tail, cap 200 ms
let outcome  = await attempt.finish(take.clip)                          // finalize + local race + deadline
// land(outcome, run):
let cleaned  = await run.cleaning.finish(modelText: heard.text, deadline: run.cleanupDeadline)
history.record(.textReady(id, cleaned.versions, cleanup: cleaned.outcome, model: heard.model, typing: typing))
let delivery = await destination.insert(cleaned.versions.cleaned, for: id, at: target)  // InsertGuard first
history.record(.delivered(id, receipt, lag: lag))                       // or .notInserted(id, reason)
```

The scorer runs the same Conductor with a recording destination: `HeadlessSystem.make(...).conductor.dictate(file:pace:)`. The hook is one line in Claude Code settings: `~/Applications/Lexicon.app/Contents/Helpers/lexicon hook claude-code`.

## Shape

### Modules

Each SwiftPM target is one module, and its dependency list is its "may import" list. Every build passes `--explicit-target-dependency-import-check error`, and `scripts/check-imports.swift` fails the build on the transitive imports that flag misses, and on any import of a sole-owner system module from the wrong place (SwiftUI and Combine: nowhere). Every import is internal unless written `public import` (`InternalImportsByDefault`), so storage and wire types can't leak through a public signature.

| Module | Owns | May import |
|---|---|---|
| `LexiconDomain` | Shared values only: `DictationID`, `DictationStatus` (with `canMove`, `isInFlight`, `needsAudio`), `TextVersions`, `SpeechSegment`, `InsertionReceipt`, `Term`/`Rule`/`RuleSet`, `Preferences`, `CloudAccess`, `AppPaths` (root only) | Foundation |
| `SQLiteKit` | One connection to system SQLite, WAL, migrations | SQLite3 |
| `KeyInput` | Event tap thread, `FnGesture`, hotkeys, `InputClock` (single writer) | Domain |
| `AudioCapture` | Engine, sink node, ring, converter, CAF writer, fsync, device rebuild, adaptive tail | Domain |
| `Transcription` | One adapter file per provider, sockets, keywords, finalize, retry, local race, residency, reachability | Domain |
| `LocalParakeet` | The FluidAudio adapter, model install and compile. The only FluidAudio importer | Domain, Transcription |
| `Cleanup` | Rules, the LLM stage (OpenRouter, on-device seam), the structural check, the rules-only fallback | Domain |
| `WordStore` | The Lexicon: terms, Rules, `lexicon.sqlite`, per-Dictation selection | Domain, SQLiteKit |
| `History` | Every durable fact about a Dictation: `history.sqlite`, `audio/`, recovery, retention, the window's reader | Domain, SQLiteKit, AudioCapture |
| `AppText` | Everything done to other apps' text: focus capture, `InsertGuard`, paste and restore, read, watch, replace | Domain, KeyInput |
| `Jev` | TypeSafe calls; every call carries a local fallback | Domain |
| `Fixes` | Hand fix watching, hook-prompt matching, Re-speak resolution, Rule proposals | Domain, History, WordStore, AppText, Jev |
| `Inbox` | Inbox file format, writer, watcher | Domain |
| `LexiconCore` | `Conductor`, `LexiconSystem`, `HeadlessSystem`, `PreferencesStore`, Keychain | all above except LocalParakeet |
| `LexiconUI` | Status item, indicator, History window, settings, fix prompt | Domain, History, AudioCapture, Fixes, Core |
| `LexiconApp`, `lexicon`, `lexicon-eval` | App shell; hook CLI (Domain and Inbox only, about 300 KB); scorer | as declared |

### Who owns what

- **The Conductor** decides the order of events for every Dictation and holds no durable state. It owns one live capture slot (one mic) and the tasks of Dictations past fn-up.
- **History** owns rows. Callers describe events (`.began`, `.audioEnded`, `.textReady`, `.delivered`, `.notInserted`, `.fixRecorded`, `.deleted`). One `apply` switch holds every row rule. A status move applies only when `canMove(to:)` allows it from the stored status, so a replayed or racing event is a no-op. A Dictation about to be typed sits in `ready` (text saved, paste in progress) until the paste's real outcome moves it to `inserted` or `notInserted`. Only History holds the final text (cleaned text plus Fixes).
- **The open `LiveCapture`** owns audio bytes until stop (`~Copyable`, stopped exactly once). After stop, the file belongs to History.
- **AppText** owns live Accessibility references, keyed by `DictationID`. The durable `InsertionReceipt` (app, field fingerprint, caret, short context) is stored by History.
- **`FnGesture`** owns gesture state on the tap thread. The Conductor asks it to end and never writes it.
- **`PreferencesStore`** owns settings. The Conductor snapshots them once at fn-down, so a mid-Dictation change never affects the Dictation in flight.

### Invariants the compiler enforces

- Recovered and retried text is never typed: `TextDestination.Target` has no public initializer, and only a live fn-up or a test file run produces one.
- No cloud call in Private mode, and no LLM Cleanup with "AI cleanup" off: speech, Jev and Cleanup take a `CloudAccess`, whose only constructor returns nil in those modes.
- Every Jev call has a local fallback: `decide(_:access:budget:fallback:)` has no other form.
- A capture is stopped, and an attempt finished, at most once: both are `~Copyable` with `consuming` methods.
- One list each, compiler-checked: providers, statuses (index predicates and retention derive from the enum), key commands, inbox messages, History events.
- The late-text rule runs on every insert: `InsertGuard.decide` is a pure function with no grace window.
- Text is never typed twice: a row left in `ready` after a crash becomes `notInserted` (reason `interrupted`) at launch; paste-last still reaches it.

### One push-to-talk Dictation

1. fn-down. The tap callback (`KeyInput/EventTap.swift`) feeds `FnGesture`, which yields `.dictationBegan`. fn passes through.
2. The Conductor starts the capture first (`AudioCapture/Recorder.swift`), so audio is in the page cache before anything else can fail. Then it records `.began` (the row exists from the start), takes the Lexicon terms, opens the speech socket (TLS overlaps speech), starts a `CleanupSession` on the attempt's finished segments, loads the local model if it isn't resident, and starts a `beginActivity(.userInitiated, .latencyCritical)` so App Nap can't slow the Dictation.
3. While Jake talks: chunks stream to the provider; finished sentences go through Rules and the LLM as they arrive.
4. fn-up. In parallel: AppText captures the target field and an input mark; the capture keeps the adaptive tail (stop on silence, cap 200 ms).
5. `attempt.finish` sends finalize and races local. The cloud final wins if it's back by the deadline (0.8 s, tuned in #19).
6. `cleanup.finish` cleans the last sentence (and may revise the one before), runs the structural check against the Rules output, and returns the LLM text or the rules-only text with the reason. A miss of the 250 ms Cleanup deadline types the rules-only text.
7. `.textReady` is queued for History (status `ready`), then `InsertGuard.decide` checks same app, same field, no input since the mark, and AppText pastes (pasteboard promise, Cmd-V). The clipboard restore, fsync, the `.delivered` write, Fix watching and Jev all run after, off the path.

### Concurrency

| Where | Runs |
|---|---|
| Core Audio IO thread | Sink block: memcpy into the SPSC ring, nothing else |
| Audio writer queue | Drain, convert to 16 kHz, write CAF, fsync each 1 s, yield chunks |
| Event tap thread (own run loop) | Tap callback in microseconds, `FnGesture`, `InputClock` |
| AX thread (own run loop, custom executor) | `TargetApp`: Accessibility calls with timeouts, observers, Cmd-V |
| Main actor | AppKit, the History window's read-only connection, pasteboard promise callbacks |
| `Conductor` actor | Lifecycle decisions, never queued behind UI |
| Speech and Cleanup actors, URLSession | Sockets, the race, LLM calls |
| History writer queue | Every `history.sqlite` write, FIFO, never awaited on the hot path |
| `LocalTranscriber` | One job at a time; live work preempts recovery and retry |

### Data

- `history.sqlite`: `dictation` (status, origin, model, cleaned and final text, speech model, lag, Cleanup outcome, audio state, pin), `attempt` (every engine try), `fix`, `insertion` (receipts). Enum columns store Swift raw values; partial indexes are generated from `DictationStatus`.
- `audio/<id>.caf`: 16 kHz mono 16-bit, retention per #4.
- `lexicon.sqlite`: terms and Rules, owned by WordStore. Contents are #21's call.
- `models/`: Parakeet weights (about 609 MB), never in the bundle.
- `inbox/`: hook and test-hook messages.
- Keychain: one item per cloud credential, service = bundle ID. `lexicon-eval` reads environment variables instead.
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
| fn-up to text, cloud | adaptive tail (0 to 200 ms) + provider final (about 130 to 200 ms) + Cleanup of the last sentence (250 ms p95 deadline) + 10 ms |

The last row adds up to about 0.7 s at p95, against Wispr's roughly 0.6 s. The tail and the Cleanup deadline are where it has to give. The lag target is [Speech pipeline](https://github.com/jparker2006/lexicon/issues/19)'s call and the tail is [fn and recording behavior](https://github.com/jparker2006/lexicon/issues/18)'s.

### How M0 to M5 land

| Milestone | Fills | Seams already there |
|---|---|---|
| M0 It types | `FnGesture` (hold), capture, Muse adapter, paste and restore, History `began`/`audioEnded`/`textReady`, `Conductor.run`, status item and indicator, `lexicon-eval` | WordStore returns empty; Cleanup is Rules plus rules-only; `SpeechPlan` is cloud only |
| M1 Never loses it | Hands-free and cancel, recovery, retention, History window, retry, paste-last, the waiting path | Row at start and CAF from M0; `land` already has the waiting branch |
| M2 Works offline | `LocalParakeet`, the race, residency, Private mode, model picker and install | `CloudAccess` gates every cloud call already |
| M3 Good enough to swap | LLM Cleanup and the structural check, Lexicon terms and code terms, bake-off adapters, first head-to-head | One adapter file per provider; `CleanupModel` seam |
| M4 Fix by voice | Re-speak trigger (#23), `Fixes.respeak`, `TargetApp.replace`, Jev close calls | `DictationPurpose.respeak` and `InsertionReceipt` exist from day one |
| M5 Learns from you | Watch windows, hook prompts through the inbox, the fix prompt (#24), Rules, light app formatting | `fixes.didInsert` runs after every insert; Rules reach Cleanup through the fn-down snapshot |

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
- We accept at-most-once inbox delivery: a lost hook prompt is a missed Hand fix, never a lost Dictation.
- We accept a 0.4 to 0.6 s local model load on the first Dictation after 10 idle minutes, in exchange for about 130 MB less memory most of the day.

## Alternatives considered

- **Three processes** (always-on agent for tap, capture and disk; UI and speech app; on-demand model service). Strongest isolation, but it buys nothing the audio file doesn't already guarantee, and it costs a second code identity, a Login Items approval, IPC on the text path and Xcode bundling.
- **SwiftUI first** (`MenuBarExtra`, SwiftUI windows). Less code per window, but no non-activating panel and no status item button control, so AppKit is needed anyway; measured slower and heavier.
- **A pipeline of stage actors** (capture, transcribe, clean, insert, store). This is temporal decomposition: status and "what next" spread across five modules, and waiting, retry and recovery each need their own wiring.
- **One module.** Simplest start, but nothing stops a builder reaching into SQL, Accessibility references or gesture state.

## Implementation reconciliation

Builders record accepted deviations here, with who accepted them, and update the usage, signatures and ownership above before the next unit starts. Architect's scrap rule applies: if the same workaround shows up across unrelated code, if types need escape hatches (`@unchecked Sendable`, casts, always-set optionals), or if two independent deviations share a shape, stop and re-run `/pstack:architect` instead of bolting fixes on.

## Hand-offs

- [fn and recording behavior](https://github.com/jparker2006/lexicon/issues/18): the 200 ms tail (#4) vs finalize at fn-up (#8). The sketch supports an adaptive tail capped at 200 ms. Also: does Esc-cancel keep the audio? Recommended: keep it, status cancelled, retryable.
- [Speech pipeline](https://github.com/jparker2006/lexicon/issues/19): the p95 lag sum above, and whether to keep a speech socket pre-opened (a cold TLS connect is up to 635 ms and can miss a very short Dictation before M2).
- [Hand fix](https://github.com/jparker2006/lexicon/issues/24): who installs the Claude Code and Codex hook config, a Settings button or Jake by hand.

## Next implementation step

Build the never-lose spine headless first: `AudioCapture`'s file input and CAF writer, History's `began`/`audioEnded`/`textReady`/recovery, and `Conductor.dictate(file:)` with the headless destination and a scripted fake provider, proven by a Swift Testing test on a short 16 kHz WAV. Then add the mic and the fn key.
