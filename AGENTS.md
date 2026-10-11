# Lexicon

Lexicon is a fast, native Swift Mac dictation app that learns your words. It replaces Wispr Flow for Jake. The design starts from `docs/grill/2026-10-10-lexicon-grill.md`; the buildable plan is the v0 spec, [#36](https://github.com/jparker2006/lexicon/issues/36), with its supersessions in the spec's first comment.

Two things are always true. Judge every change against them:

- **If Lexicon is worse than Wispr Flow on Jake's own voice, he won't use it.** Fewer words wrong, fewer tech words wrong, lag at or under Wispr's, works offline, never loses a dictation.

- **Ridiculously fast and ridiculously small.** Native Swift, no web views, no heavy dependencies. Every byte and millisecond has to earn its place.

## Working with Jake

- Jake is a solo developer. He often dictates prompts. Read for what he means, not the exact words.
- Write plainly and briefly. Lead with the result. No em dashes.
- Decide small, reversible things yourself and say what you chose. Ask only when the answer would change the outcome, and bring a recommendation.
- Before you finish, compare the result with what he asked, including later corrections. If an obvious next step is inside the request, do it. Otherwise say exactly what is unfinished and why.

## Where things are

- `docs/architecture.md`: modules, who owns what, the invariants the compiler enforces, budgets. Where it predates the spec, the spec wins.
- `docs/adr/`: decisions that are hard to reverse. `GLOSSARY.md`: the words to use.
- `docs/agents/`: how Jake, the orchestrator, builders and the Reviewer work ([workflow.md](docs/agents/workflow.md)), the review checklist ([review.md](docs/agents/review.md)), labels and the issue tracker.
- `.claude/skills/`: `implement-ticket`, `pr`, `orchestrator-handoff`. `.claude/agents/`: the Haiku helpers. `.claude/hooks/guard.mjs`: the guard hook.
- Code lands with the architecture skeleton ticket ([#38](https://github.com/jparker2006/lexicon/issues/38)): `Package.swift`, one SwiftPM target per module under `Sources/`, the check script under `scripts/`, CI under `.github/`.

## Commands

Command Line Tools 26.6 only (Swift 6.3, macOS 26 SDK), SwiftPM, no Xcode ([ADR 0003](docs/adr/0003-command-line-tools-only.md)).

- The check script from #38 runs `swift build` with the import check, the import-check script and `swift test`. Run it once on the finished change.
- CI runs the same check script on macOS for every push and PR and reports one check, named `CI`. A red run means the change isn't done.
- Worktrees share SwiftPM's one dependency cache (the default; never pass `--disable-dependency-cache`). Each worktree has its own `.build/`, deleted with the worktree once its ticket merges.

## Dev builds and the live app

- Builders build and run **Lexicon Dev**: its own bundle ID, its own data folder (`~/Library/Application Support/Lexicon Dev/`), signed with the self-signed "Lexicon Dev" certificate, installed at `~/Applications/Lexicon Dev.app` and launched with `open`, never by running the binary from a shell (the fn tap refuses that, [ADR 0001](docs/adr/0001-one-process.md)).
- Jake's daily copy, **Lexicon** at `~/Applications/Lexicon.app`, is his. Builders never install over it, quit it, or reset or touch its permissions. `tccutil reset` only ever names the Lexicon Dev bundle ID.
- **One live-app lane.** Only one builder at a time drives the live app (fn, the mic, paste, Accessibility). Everything else runs headless: the real pipeline on a WAV file, with no mic, keys or network.

## Private data

Jake's Wispr export, the Test set and its gold text, the starter Lexicon, his History and his keys never enter git, a PR, an issue, a log, or any agent's or chatbot's context. They live under `~/Library/Application Support/Lexicon/` (keys also in the login Keychain and `~/code/lexicon/.env`). Agents never open them; scripts such as `lexicon-eval` read them on the Mac. Refer to them by path only, and never print a key. Eval runs may send Test set audio and text only to the providers Lexicon itself uses, with zero retention. Test fixtures are synthesized or recorded for the test, never Jake's recordings.

## Doing the work

A builder builds its ticket with the implement-ticket skill (`.claude/skills/implement-ticket/SKILL.md`; in Claude Code, call the Skill tool with "implement-ticket"). It runs from claim to hand-off and carries the details of the steps below.

1. **Start from an issue.** GitHub issues are the shared to-do list. Claim an unclaimed one: comment "Building: taking this (Claude)", add `building` and remove `ready-for-agent`. A real change with no issue gets one first.
2. **Stay in your own lane.** Work in your own worktree and leave changes you did not make alone. On a conflict, what's already merged wins: resolve in its favor unless keeping it would break your ticket.
3. **Test first where the issue names a seam.** A bug fix gets a test that fails before the fix.
4. **Check once, on the finished change,** with the check script. All green, or say what is red and why.
5. **Commit small, only your own files, with explicit paths.** Message: `type(scope): what changed (#N)`. Link the issue with `Refs #N`, never a closing keyword, in commits and PR bodies alike.
6. **Everything lands by PR, and only the Reviewer merges.** Merge `main` into your branch, never rebase a pushed one. Nobody pushes to `main`; the guard hook refuses it. Write the PR body with the `pr` skill.
7. **Close the loop:** a builder's last comment on its issue is the skill's Ready line.

## Done means verified

- Check the thing Jake will actually use, not just that it builds. For behavior, run the headless pipeline on a WAV. For UI, insertion or fn, use the live-app lane.
- A change to speech or Cleanup runs a quick `lexicon-eval` and puts the scores in the PR; a score that got worse is flagged there.
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

- Installing over the daily copy. Only the Reviewer runs the install command, and only on Jake's "install".
- Anything that spends or sends outside the repo: paid APIs, cloud speech or LLM calls on real data, new accounts.
- Deleting private data anywhere, or touching the daily copy's permissions.
- Destructive git: `reset --hard`, `clean`, force-push, rewriting pushed history.

Never start Docker on the Mac: it can crash the machine mid-build. Stop processes only by the PIDs you started, never by name.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues (jparker2006/lexicon), read and written with `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default roles, each label named after its role (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix), plus the work-state labels building, waiting-on-jake, parked. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created when first needed. See `docs/agents/domain.md`.
