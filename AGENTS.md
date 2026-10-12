# Lexicon

Lexicon is a fast, native Swift Mac dictation app that learns your words. It replaces Wispr Flow for Jake. The design starts from `docs/grill/2026-10-10-lexicon-grill.md`; the buildable plan is the v0 spec, [#36](https://github.com/jparker2006/lexicon/issues/36). Every decision made since the spec, each with Jake's own words or marked Proposed until he gives them, lives in [docs/DECISIONS.md](docs/DECISIONS.md), which wins where the two disagree.

Two things are always true. Judge every change against them:

- **If Lexicon is worse than Wispr Flow on Jake's own voice, he won't use it.** Fewer words wrong, fewer tech words wrong, lag at or under Wispr's, works offline, never loses a dictation.

- **Ridiculously fast and ridiculously small.** Native Swift, no web views, no heavy dependencies. Every byte and millisecond has to earn its place.

## Working with Jake

- Jake is a solo developer. He often dictates prompts. Read for what he means, not the exact words.
- Write plainly and briefly. Lead with the result. **No em dashes** in anything Jake reads: chat, UI copy, notices, PR bodies, issue comments and docs. This is the rule's one home; review.md and the skills point here.
- Decide small, reversible things yourself and say what you chose. Ask only when the answer would change the outcome, and bring a recommendation.
- **A question says what Jake will see or feel,** and defines in the same sentence any word that isn't in `GLOSSARY.md`. A decision gets plain option words, what each option does for him, one recommendation, and a reply that takes it ("Reply yes to take that"). Who asks is in [workflow.md Roles](docs/agents/workflow.md#roles).
- **Every time, count or state you give Jake comes from a command you ran in that turn** (`scripts/status.sh`, `scripts/ticket-times.sh`, `scripts/machine.sh`, `gh`), or is labelled an estimate or unverified.
- **Do the step yourself.** Run, open, bring forward, pull and check things yourself; hand Jake only what needs his hands or his decision. An ask that names an app or a file gives its full path.
- Before you finish, compare the result with what he asked, including later corrections. If an obvious next step is inside the request, do it. Otherwise say exactly what is unfinished and why.

## Where things are

- `docs/DECISIONS.md`: every decision since the spec, current and replaced, each with Jake's words, the question and the time, or marked Proposed until he gives them. A change that departs from the spec or a recorded decision updates it in the same PR.
- `docs/architecture.md`: modules, who owns what, the invariants the compiler enforces, budgets and how each is read.
- `docs/adr/`: decisions that are hard to reverse. `GLOSSARY.md`: the words to use.
- `docs/agents/`: how Jake, the orchestrator, builders, Live checks and the Reviewer work ([workflow.md](docs/agents/workflow.md)), the review checklist ([review.md](docs/agents/review.md)), labels and the issue tracker.
- `.claude/skills/`: the repo's skills, starting with `implement-ticket` and `pr`. `.claude/agents/`: the typed helpers. `.claude/workflows/`: the `lexicon-review` Workflow. `.claude/hooks/guard.mjs`: the guard hook.
- Code: `Package.swift`, one SwiftPM target per module under `Sources/`, tests under `Tests/`, the check script `scripts/check.sh` with its steps in `scripts/checks/`, CI in `.github/workflows/ci.yml`. Every script under `scripts/` says what it does in its header.

## Commands

Command Line Tools 26.6 only (Swift 6.3, macOS 26 SDK), SwiftPM, no Xcode ([ADR 0003](docs/adr/0003-command-line-tools-only.md)).

- The check script (`scripts/check.sh`) runs `swift build` with the import check, the import-check script, `swift test`, the scorer's tests, `lexicon-eval` on the public fixture manifest (the scorer needs `uv`) and every step in `scripts/checks/`. It runs in one of two build slots (`scripts/lib/heavy.sh`). Run it once on the finished change.
- CI runs the same check script on macOS for every push and reports one check, named `CI`. A newer push to a branch cancels that branch's older run. A red run means the change isn't done.
- Worktrees share SwiftPM's one dependency cache (the default; never pass `--disable-dependency-cache`). Each worktree has its own `.build/`, removed with the worktree when its PR merges.

## Dev builds and the live app

- The Live checks session builds and runs **Lexicon Dev**: its own bundle ID, its own data folder (`~/Library/Application Support/Lexicon Dev/`), signed with the self-signed "Lexicon Dev" certificate, installed at `~/Applications/Lexicon Dev.app` and launched with `open`, never by running the binary from a shell (the fn tap refuses that, [ADR 0001](docs/adr/0001-one-process.md)).
- Jake's daily copy, **Lexicon** at `~/Applications/Lexicon.app`, is his. Only the Reviewer installs over it (`scripts/install.sh`). Only the Live checks session quits it, from its own menu and only while no Dictation is in progress, at the start of a sitting with fn steps, and reopens it at the end (`scripts/live-lane.sh daily`); nobody force-kills it. Nobody resets or touches its permissions: `tccutil reset` only ever names the Lexicon Dev bundle ID.
- **One live-app lane, held by the Live checks session.** Only it drives the live app (fn, the mic, paste, Accessibility). `scripts/dev-run.sh` and `scripts/harness.sh` refuse any session that doesn't hold the lane lock (`scripts/live-lane.sh`). Builders run headless: the real pipeline on a WAV file, with no mic, keys or network, and post a typed request for what needs the live app ([workflow.md Live checks](docs/agents/workflow.md#live-checks)).

## Private data

This is the private-data rule's one home; review.md, the skills and the helper briefs point here.

- Jake's Wispr export, the Test set and its gold text, the starter Lexicon, his History and his keys never enter git, a PR, an issue, a log, or any agent's or chatbot's context. They live under `~/Library/Application Support/Lexicon/` (keys also in the login Keychain and `~/code/lexicon/.env`). Agents never open them; scripts such as `lexicon-eval` read them on the Mac. Refer to them by path only, and never print a key. The guard hook and `.claude/settings.json` refuse those paths for every tool.
- **Numbers on GitHub:** nothing measured on Jake's own Wispr history or his History goes into the repo, a PR or an issue: no counts, totals, lag or word figures from it. Test set sizes (clips, minutes of audio, split sizes) and eval scores may go anywhere.
- Eval runs may send Test set audio and text only to the providers Lexicon itself uses, with zero retention; that is the one exception to "Ask Jake first" for calls on real data.
- Test fixtures are synthesized or recorded for the test, never Jake's recordings.

## Doing the work

A builder builds its ticket with the implement-ticket skill (`.claude/skills/implement-ticket/SKILL.md`; in Claude Code, call the Skill tool with "implement-ticket"). It runs from claim to hand-off and carries the details of the steps below.

1. **Start from an issue.** GitHub issues are the shared to-do list. Claim an unclaimed one with `scripts/ticket.sh claim N`. A real change with no issue gets one first.
2. **Stay in your own lane.** Work in your own worktree and leave changes you did not make alone. On a conflict, what's already merged wins: resolve in its favor unless keeping it would break your ticket. **Only the orchestrator posts chips** (the one-click cards that start a session). Out-of-scope work you find becomes a `later` issue (`scripts/ticket.sh later <pr> "<note>" --owner <issue>`, or `--new`), named in your Ready line; the orchestrator decides whether and when it becomes a chip.
3. **Test first where the issue names a seam.** A bug fix gets a test that fails before the fix.
4. **Check once, on the finished change,** with the check script. All green, or say what is red and why.
5. **Commit small, only your own files, with explicit paths.** Message: `type(scope): what changed (#N)`. Link the issue with `Refs #N` and **never a closing keyword** (any form of close, fix or resolve before an issue number), in commits and PR bodies alike: the merge script closes the issue itself, with a comment naming the PR. This is the rule's one home.
6. **Everything lands by PR, and only the Reviewer merges,** with `scripts/merge-pr.mjs`. Bring `main` in only to resolve a conflict, by merge, never by rebasing a pushed branch. Nobody pushes to `main`; the guard hook refuses it. Write the PR body with the `pr` skill.
7. **Close the loop:** a builder's last comment on its issue is its Ready line (`scripts/ticket.sh ready N`).

## Done means verified

- Check the thing Jake will actually use, not just that it builds. For behavior, run the headless pipeline on a WAV. For UI, insertion or fn, post a Live checks request.
- A change to speech or Cleanup runs a quick eval (`scripts/eval-quick.sh`) and puts the scores in the PR; a score that got worse is flagged there.
- Say what you could not check.
- A plan, a passing build or a list of findings is progress, not done.

## Tests

- Test behavior through the highest public seam (the headless pipeline, then the pure seams), not implementation details. No tests that read source files or pin values expected to change.
- Tests never need the mic, keys or network, and never depend on machine speed: use a fake clock or an explicit signal.

## Code

- Choose the simplest implementation that fully meets the issue. No speculative options, layers or config.
- When something is replaced, delete the old path. No compatibility shims.
- AppKit only; SwiftUI and Combine are never imported. FluidAudio is the only third-party package in the app; any other needs Jake's yes.
- Code may be copied from MIT, Apache or BSD projects with their copyright lines kept. GPL projects (VoiceInk, FluidVoice): ideas only, never code.
- Comments say why the code is the way it is. History (bugs, tickets, incidents) goes in commit messages.

## Ask Jake first

- **An approval counts only in the session that acts on it** ([DECISIONS.md](docs/DECISIONS.md), grill Q1). It reaches that session in one of two ways: in the chip Jake clicks, with its exact scope (a call count, an endpoint, a text set, a date), or typed by Jake in that session when it asks. A yes relayed from another session never counts, so nobody writes "Jake said yes" for another session; the orchestrator tells Jake which session to answer in. Anything outside the named scope stops and asks there. Standing approvals are the dated list in `CLAUDE.md` and each role's start prompt. Decisions about the product are different: they are recorded once in DECISIONS.md and travel from there.
- Installing over the daily copy: only the Reviewer runs `scripts/install.sh`, on Jake's "install" typed in its session or under the standing install rule in its start prompt.
- Anything that spends or sends outside the repo: paid APIs, cloud speech or LLM calls on real data (eval runs aside, as Private data says), new accounts.
- **The plan only:** no fast mode (`.claude/settings.json` turns it off), no usage credits or pay-as-you-go, and no `--bare` runs, which bill outside the plan.
- Deleting private data anywhere, or touching the daily copy's permissions.
- Destructive git: `reset --hard`, `clean`, force-push, rewriting pushed history.

Never start Docker on the Mac: it can crash the machine mid-build. Stop processes only by the PIDs you started, never by name.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues (jparker2006/lexicon), read and written with `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default roles, each label named after its role (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix), the work-state labels building, waiting-on-jake, parked, and the flags `critical-path` and `later`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
