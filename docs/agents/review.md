# PR review checklist

Every reviewer uses this: the Reviewer session, the orchestrator, and builders reviewing their own diff before they open a PR. Each item is a way a green PR can still hurt Lexicon. Words follow `GLOSSARY.md`; the design is the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)) and `docs/architecture.md`.

A review ends in one verdict: **merge**, **merge with notes**, or **don't merge**. Give each problem a file and line and a one-line failure scenario ("X happens, so Y"). Only blockers get built. Notes that don't block go on the spec's "Later" list (one comment on the parent spec issue, edited in place), never a new issue and never a chat-only remark; Jake promotes a Later item to an issue when he wants it. The Reviewer merges its own merge verdicts as `workflow.md` says under Merging; Jake can hold any PR. Installing is the Reviewer's too, only on Jake's "install".

## Risk tiers

- **High:** anything that touches audio capture, History or its recovery, inserting text, the network (`CloudAccess`, any provider, model downloads), private data, keys, the Secret guard, Private mode, the fn tap, permissions, signing, the bundle or install scripts, the guard hook or `.claude/`. The Reviewer reads the full diff itself. When it touches audio capture, History, insertion, network access or private data, it also runs `/pstack:blast-radius` on it.
- **Low:** copy, docs, tests, and contained fixes outside those paths. The Reviewer checks the riskiest hunk and the tests, then decides.
- When unsure, it's high.

## Never lose a Dictation

- Audio is on disk within the first 100 ms of a Dictation, and what was captured survives a crash mid-Dictation.
- A capture is stopped, and a speech attempt finished, at most once. Check every path that could stop it twice or never: fn-up, Esc, the 20-minute cap, a device change, an engine error.
- Every Dictation's History row is written at fn-down, when recording starts, and every status move is one the status list allows. A replayed or racing event is a no-op, never a second row or a skipped state.
- Text is queued for History (status ready) before it's typed. Nothing on the fn-up path waits on SQLite, Jev or Fix watching.
- A row left mid-paste after a crash becomes "not inserted" at launch and is never retyped. Recovered or retried text can't be typed; it waits for paste-last.
- When no engine can produce text, the Dictation is marked waiting and retried; Jake is never asked to redo it.
- Nothing in History or the audio folder is deleted except by retention, Jake's own delete, or a lone tap removing its own row and audio.

## Inserting text

- `InsertGuard.decide` runs on every insert. Late text, or text whose target is gone or changed, waits for paste-last instead of landing in the wrong place. No grace window, except the spec's fallback where an app's field can't be detected (same app and under 5 s).
- The clipboard is restored after paste, and a restore never overwrites something Jake copied in between.
- Insertion works in the four apps that matter: Claude desktop, ChatGPT (Codex), a native text field, a terminal. A change here says which it checked in the live-app lane.

## Network, keys and private data

- `CloudAccess` is the only door to the network. No `URLSession`, socket or download outside it. Its constructor returns nothing in Private mode or for an always-private app, and revocation mid-Dictation cuts the stream at once.
- Every text-sending call passes the Secret guard first. Every Jev call has a local fallback.
- Requests carry zero retention where the spec says (`zdr: true` on OpenRouter), and audio goes only to services Lexicon itself uses.
- Keys come from the Keychain (`lexicon-eval` reads environment variables). No key in code, a log, a test, a fixture, a PR, a comment or a commit.
- Jake's Wispr export, the Test set and its gold text, the starter Lexicon and his History are referred to only by path under `~/Library/Application Support/Lexicon/`. Nothing from them is committed, quoted or pasted into GitHub, and no agent or chatbot reads them. Only eval runs send Test set audio and text, and only to the providers Lexicon itself uses, with zero retention. Test fixtures are synthesized or recorded for the test.
- No raw error text, file paths with Jake's data or private records reach the UI or a log that leaves the Mac.

## Shape and budgets

- Module boundaries hold: a target imports only what its dependency list allows, and the import check passes. SwiftUI and Combine are never imported.
- FluidAudio is the only third-party package in the app, and only `LocalParakeet` imports it. A new package needs Jake's yes, named at the top of the review.
- Copied code comes only from MIT, Apache or BSD projects, with their copyright lines kept. GPL code (VoiceInk, FluidVoice) is never copied.
- The change stays within budget, or the PR says by how much it moves: app binary 4 MB or less without FluidAudio, bundle 12 MB or less with it, idle memory 30 MB or less with the model unloaded, launch to fn working 150 ms or less, fn-down to first audio 60 ms or less, Lexicon's own fn-up to Cmd-V work 10 ms or less.
- Every lag, memory or speed number in the PR went through `/pstack:benchmark-checklist` before it was reported.
- One owner per thing, as `docs/architecture.md` says. A new piece of shared mutable state, a lock, or a second writer to History is a blocker unless the PR argues it.
- When the PR contradicts an ADR, it says so and why.

## Scores

- A change to speech, Cleanup or the Lexicon runs a quick `lexicon-eval` and puts the scores in the PR (words heard right, Terms right, lag). **Any score that got worse is flagged at the top of the PR**, and a silent regression is a blocker.
- Agents never tune on the 100 held-back clips. The full held-back run is per milestone.

## Combining with main

- Green alone is not green together. Check the PR against the other open PRs and the newest `main`: same files, same module's dependency list, same status list. Name the merge order.
- Wait on CI with `gh pr checks <pr> --watch`, on the `CI` check of the reviewed head. After each merge, the next PR must be brought up to date and go green again before it merges.

## Correctness traps

- GitHub refusals (403, 405, 409) are definite "not done", not "unknown".
- Swift 6 strict concurrency: no `@unchecked Sendable` or `nonisolated(unsafe)` without a comment saying why it is safe. Audio and the fn tap run off the main actor; UI runs on it.
- Every wait has a deadline: the race cutoff, the Cleanup deadline, Jev, network reads. A timeout falls back; it never drops the Dictation.
- A transient error is never a permanent decision: a timeout or 5xx retries or falls back, it never marks a Dictation lost.

## Live app and permissions

- The live app is the Lexicon Dev build, launched with `open`. Nothing resets or touches the daily copy's permissions, and `tccutil reset` names only the dev bundle ID.
- Only Microphone and Accessibility are requested. A new permission or entitlement is high risk and named in Merge Danger.

## Tests and copy

- Tests go through the highest public seam: the headless pipeline on a WAV first, then the pure seams. No source-reading tests. The test for a fix fails before the fix.
- Tests never need the mic, keys or network, and never depend on machine speed: use a fake clock or an explicit signal.
- A test that has turned CI red with no code cause is a blocker, never Later.
- No em dashes in anything Jake reads: UI copy, notices, PR bodies.
- The PR's `## Install` section lists every step installing it needs (a new permission, a data migration, a model download), or "Code only."
