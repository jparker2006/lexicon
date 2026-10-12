# PR review checklist

Every reviewer uses this: the Reviewer session, the orchestrator, and builders reviewing their own diff before they open a PR (through the `lexicon-review` Workflow, which runs a critic per section below). Each item is a way a green PR can still hurt Lexicon. Words follow `GLOSSARY.md`; the design is the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)), `docs/DECISIONS.md` and `docs/architecture.md`.

A review ends in one verdict: **merge**, **merge with notes**, or **don't merge**, naming the head sha it reviewed. Give each problem a file and line and a one-line failure scenario ("X happens, so Y"). Only blockers get built ([What blocks](#what-blocks)). A note that doesn't block becomes an issue labelled `later` (`scripts/ticket.sh later`), owned by the open ticket that will fix it or new for triage, and the verdict lists it under "Later:" with its number; a note that must land before #X becomes a blocker on #X. Never a chat-only remark. The Reviewer merges its own merge verdicts with `scripts/merge-pr.mjs`, as `workflow.md` says under Merging; Jake can hold any PR. Installing is the Reviewer's too, only on Jake's "install".

## Risk tiers

`.claude/workflows/review-map.json` lists the high-tier paths; when unsure, it's high.

- **High:** anything that touches audio capture, History or its recovery, inserting text, the network (`CloudAccess`, any provider, model downloads), private data, keys, the Secret guard, Private mode, the fn tap, permissions, signing, the bundle or install scripts, the guard hook or `.claude/`. The Reviewer runs the full review Workflow on it in Reviewer mode and reads the full diff itself. When it touches audio capture, History, insertion, network access or private data, it also runs `/pstack:blast-radius`, and the PR carries the proof command.
- **A high-tier merge needs live evidence for the exact head it merges** when its ticket has live items: a `Live checks: <branch> @ <sha7>` result with no FAIL that names that head, not an earlier one (#133 merged at a head no live run had checked). Items that need Jake's hands don't hold the merge: they are checked on `main` in his next sitting, and nothing installs until they pass (grill Q6). `scripts/merge-pr.mjs` refuses a merge without it.
- **Low:** copy, docs, tests, scripts, and contained fixes outside those paths. A light pass: the riskiest hunk and the tests, relying on the builder's own verified `## Review` table.

### The Reviewer's duties

This is their one home; workflow.md points here.

- **Watch, don't wait to be told.** Keep `scripts/watch-events.sh --role reviewer` running and act on each Ready, Fixed review, CI and head-moved line as it lands. A Ready PR needs no message from anyone, and an approved PR behind `main` needs no builder: the merge script updates it.
- **In parallel, not in a line.** When several PRs are Ready, review them at the same time, one review Workflow or swarm per PR, never one after another.
- **Depth by tier.** High tier: the full review Workflow (`mode: "reviewer"`, with the PR's risks), a critic per lens and a verifier per finding. Low tier: the light pass above.
- **One pass, all findings.** Every blocker goes in the first verdict, so a PR comes back as few times as possible.
- **The opt-in comes with the session.** Jake's standing opt-in to review Workflows and swarms (grill Q4, `docs/DECISIONS.md`) is in the Reviewer's start prompt, so it never waits for a relayed one.

## What blocks

- A finding that predicts **nondeterminism** (an outcome that depends on timing or order), **a hang** (a wait with no deadline), or **a change of meaning** in Jake's text (Cleanup, a Rule or a Retry that drops or changes what he said) blocks the merge and never becomes a `later` note. #96's spoken-year finding was parked as a note and shipped; it is #163 now.
- **"Flaky" is a diagnosis.** It needs the full failed log and the same failure on a clean `origin/main`. Without both, the PR's own change is the cause and the red run blocks (#102's red run was its own compile-check tests, not #95's flake).
- A PR that **writes data nothing reads**, or meets an acceptance line only in part, names the ticket that finishes it (`scripts/ticket.sh ac` marks the line moved).
- **Decisions are Jake's words.** Never record a decision as Jake's without his words, the question and the time (`docs/DECISIONS.md` says how). A departure from the spec or a recorded decision found in review is a question for Jake with a recommendation, asked as workflow.md Roles says, never a default that ships. A PR that departs gets one Opus second opinion on the departure, recorded in the PR, and changes `docs/DECISIONS.md` in the same PR, or links the entry that already allows it.

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
- The clipboard is restored after paste, and a restore never overwrites something Jake copied in between. The one exception is a missed paste's 2 s hold (`docs/DECISIONS.md` item 26).
- Insertion works in the four apps that matter: Claude desktop, ChatGPT (Codex), a native text field, a terminal. A change here cites the Live checks comment saying which it checked.

## Network, keys and private data

- `CloudAccess` is the only door to the network. No `URLSession`, socket or download outside a call that takes one. Its constructor returns nothing in Private mode or for an always-private app, and revocation mid-Dictation cuts the stream at once.
- Every text-sending call passes the Secret guard first. Every Jev call has a local fallback.
- Requests carry zero retention where the spec says (`zdr: true` on OpenRouter), and audio goes only to services Lexicon itself uses.
- Keys come from the Keychain (`lexicon-eval` reads environment variables). No key in code, a log, a test, a fixture, a PR, a comment or a commit.
- Private data follows AGENTS.md's Private data section, its one home. In review: nothing from Jake's private data in the diff, the PR or a comment, and nothing measured on his Wispr history or his History (no counts, totals, lag or word figures from it); Test set sizes and eval scores are fine.
- No raw error text, file paths with Jake's data or private records reach the UI or a log that leaves the Mac.

## Shape and budgets

- Module boundaries hold: a target imports only what its dependency list allows, and the import check passes. SwiftUI and Combine are never imported.
- A PR that touches 3 or more modules under `Sources/` links its `Sketch:` comment, the architect sketch posted on its issue before the code.
- FluidAudio is the only third-party package in the app, and only `LocalParakeet` imports it. A new package needs Jake's yes, named at the top of the review.
- Copied code comes only from MIT, Apache or BSD projects, with their copyright lines kept. GPL code (VoiceInk, FluidVoice) is never copied.
- The change stays within the budgets in `docs/architecture.md`, each read the way its row says, or the PR says by how much it moves.
- Every lag, memory or speed number in the PR comes from `scripts/bench.sh` output or `bench-runner`'s table, and went through `/pstack:benchmark-checklist` before it was reported.
- One owner per thing, as `docs/architecture.md` says. A new piece of shared mutable state, a lock, or a second writer to History is a blocker unless the PR argues it.
- When the PR contradicts an ADR, it says so and why.

## Scores

- A change to speech, Cleanup or the Lexicon runs a quick `lexicon-eval` and puts the scores in the PR (words heard right, Terms right, lag). **Any score that got worse is flagged at the top of the PR**, and a silent regression is a blocker.
- Agents never tune on the 100 held-back clips. The full held-back run is per milestone.

## Combining with main

- Green alone is not green together. Does the PR share files, a module's dependency list or the status list with another open PR or the newest `main` (`scripts/lanes.sh`)? Which merges first, and does either need the other's change?
- Would the reviewed head still be right on the newest `main`? The merge script brings `main` in and waits for CI on that exact head before it merges; a review only needs to ask whether something on `main` since the PR branched changes what the diff means.

## Correctness traps

- GitHub refusals (403, 405, 409) are definite "not done", not "unknown".
- Swift 6 strict concurrency: no `@unchecked Sendable` or `nonisolated(unsafe)` without a comment saying why it is safe. Audio and the fn tap run off the main actor; UI runs on it.
- Every wait has a deadline: the race cutoff, the Cleanup deadline, Jev, network reads. A timeout falls back; it never drops the Dictation.
- A transient error is never a permanent decision: a timeout or 5xx retries or falls back, it never marks a Dictation lost.
- A zero-argument `URL.path()` percent-encodes "Application Support"; use `path(percentEncoded: false)`. `scripts/checks/21-source-lints.sh` refuses it.

## Live app and permissions

- The live app is the Lexicon Dev build, launched with `open`. Nothing resets or touches the daily copy's permissions, and `tccutil reset` names only the dev bundle ID.
- Only Microphone and Accessibility are requested. A new permission or entitlement is high risk and named in Merge Danger.

## Tests and copy

- Tests go through the highest public seam: the headless pipeline on a WAV first, then the pure seams. No source-reading tests. The test for a fix fails before the fix.
- Tests never need the mic, keys or network, and never depend on machine speed: use a fake clock or an explicit signal. A `// timing-ok:` line discloses each allowed exception (`docs/DECISIONS.md` lists what it covers).
- A test that has turned CI red with no code cause is a blocker, never a `later` note.
- No em dashes in anything Jake reads (AGENTS.md, Working with Jake).
- The PR's `## Install` section lists every step installing it needs (a new permission, a data migration, a model download), or "Code only."
