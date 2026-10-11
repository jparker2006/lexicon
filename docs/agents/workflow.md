# How we work: Jake, the orchestrator, builders and the Reviewer

Lexicon is built by Claude Code sessions running locally on Jake's Mac. No cloud builders. Jake decides what gets built and when it's installed; agents do the rest, toward the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)).

## Roles

- **Jake** answers grills, approves, and says "install". He is the bottleneck on purpose: keep his decisions small, clear and few.
- **Orchestrator** (one long-running Claude Code session, Opus high, in its own worktree): keeps the map of issues, grills Jake on cross-cutting work, writes specs, tickets and builder prompts, and starts builders. It never merges and never installs.
- **Builders** (Claude Code, Opus high, each in its own worktree): build one ticket, or an approved sequence from one spec in dependency order, with the implement-ticket skill. A ticket boundary does not need a fresh session. A builder ends at an open PR and a Ready comment; it never merges.
- **Live checks** (one Claude Code session, Opus high, in its own worktree): the only session that builds, launches or drives Lexicon Dev, and the only one that asks Jake to do something physical (press fn, focus a field). It holds the live-app lane, runs builders' checklists on their branches as [Live checks](#live-checks) says, and posts the results on their issues. It never commits to a builder's branch, fixes what fails, or merges.
- **Reviewer** (one Claude Code session, Opus high, in the main checkout `~/code/lexicon`): Jake starts it there, with no worktree, when PRs need review; the orchestrator writes its prompt. It reviews every green PR against [review.md](review.md) and gives one verdict per PR: merge, merge with notes, or don't merge. It is the only one who merges, one PR at a time, as [Merging](#merging) says, and it merges its own merge verdicts without waiting for Jake. It never merges a "don't merge" and holds what Jake says to hold. It names the merge order, resolves trivial conflicts without force-pushing, and puts non-blocking notes on the parent spec's Later list. There is no Deployer: on Jake's "install", the Reviewer runs the install command, as [Installing](#installing) says. Past about 1,500 messages, or when it slows down, it hands off with `/orchestrator-handoff reviewer`.

The guard hook (`.claude/hooks/guard.mjs`) backs this up: it refuses every push to `main`, and refuses a merge from any session not started in the main checkout. That is why builders and the orchestrator always run in worktrees, and only the Reviewer runs in `~/code/lexicon`.

A role session posts a finding on its issue before asking Jake about it, and asks in plain text, never with AskUserQuestion or another blocking question tool. Continuity between role sessions goes only through `/orchestrator-handoff [role]`.

## Models and helpers

- The orchestrator, builders and the Reviewer run Opus at high effort.
- Each fans its work out to Haiku 5.5 helpers at xhigh effort (`.claude/agents/`): `Explore` scouts, `editor` changes its own disjoint files, `critic` reviews one review.md section, `verifier` tries to disprove one finding. Size single helpers to the work, up to about 15 on a hard ticket; a `/pstack:swarm` run goes much wider (see pstack below). Helpers may start their own helpers. Use a Sonnet or Opus subagent where judgment matters.
- The session itself runs every commit, push, GitHub write and heavy build (the check script, `lexicon-eval`), once.

## pstack

pstack is poteto's skill set, installed as a Claude Code plugin. The Matt Pocock skills run the loop below; a pstack skill is a tool for one job inside it and runs only when someone calls it by name. Its session routing hook stays off (`session hook: off` in `~/.claude/pstack-models.md`, which also sets the model for each pstack role).

| Tool | Who | When |
|---|---|---|
| `/pstack:swarm` | Builders | The default way to fan out when a task splits into parallel pieces: Haiku workers at xhigh, each with a standalone brief, drained into one report. Go wide (below). |
| `/pstack:architect` | Orchestrator | Before it writes or starts a ticket that touches 3 or more modules, and when builders keep working around the design. A builder that hits the scrap rule in `docs/architecture.md` stops and hands back as implement-ticket's Need Jake says, so the rerun goes through the orchestrator. |
| `/pstack:blast-radius` | Reviewer | On high-risk PRs that touch audio capture, History, insertion, network access or private data. It looks for what the change breaks outside the diff and proves the one fact it is safe because of by running code. |
| `/pstack:benchmark-checklist` | Whoever reports a lag, memory or speed number | Before the number goes into a PR, an issue or a decision. |
| `/pstack:create-verification-skill` | The Live checks session, once | After the test hooks and Accessibility harness ([#45](https://github.com/jparker2006/lexicon/issues/45)) land. It writes the repo's skill for driving Lexicon Dev the way Jake does. |
| `/pstack:maintain-verification-skill` | The Live checks session | At the end of each milestone after that, to keep the verification skill true. Its live pass drives the app, so it needs the lane. |
| `/pstack:correct`, `/pstack:reflect` | Jake and the orchestrator | At the end of each milestone, in its retro (M0's is [#88](https://github.com/jparker2006/lexicon/issues/88)). `correct` turns mistakes agents keep repeating into checks that catch them; `reflect` turns a session's lessons into edits on existing skills. |
| `/pstack:unslop` | Whoever writes it | On text Jake reads: UI copy, notices, onboarding, the README. |
| `/pstack:how`, `/pstack:why` | Anyone | Investigation: `how` traces how code runs, `why` digs through history for the reasons behind its shape. |

**Swarms go wide.** Workers run on Haiku because it is cheap and fast, and that only pays off in numbers. Ask for at least 10 workers, normally 20 to 40, up to about 50. Cut the work fine: one file, one function, one test case, one review lens or one Term per worker. When the pieces run out before the count does, race several workers on the same brief and declare `best-of` or `rank all` up front. Only a job with fewer than about 5 pieces that can't be cut finer goes to single `editor` helpers instead. The step 4 review keeps its `critic` and `verifier` helpers.

- The worker model comes from the `swarm workers` line in `~/.claude/pstack-models.md`, set to `haiku @xhigh`. If that line goes missing, pstack falls back to Opus.
- pstack gives workers every tool, so each brief carries the helper rules: no commits, pushes, GitHub writes, check script, `lexicon-eval` or bundle script; no live app; no private data; write only your own files or output folder.
- Worker results are leads, like any helper's: the builder reviews every diff, and a finding counts only after a verifier or the builder's own read confirms it.

Deliberately not used:

- `poteto-mode` and the routing hook: they take over the session and would replace the Matt Pocock flow.
- `babysit` and `fix-merge-conflicts`: `babysit` shepherds a PR to mergeable and `fix-merge-conflicts` resolves conflicts on its own terms. Merging is the Reviewer's alone, and builders bring `main` in as implement-ticket step 5 says.
- `interrogate`: left out for now. The grill dropped it because it needed the Codex and Grok CLIs; the installed version (0.9.81) runs Claude subagents instead, so it can come back if `blast-radius` proves too narrow.
- pstack's `tdd`: Matt Pocock's `tdd` skill already covers test-first.

## Concurrency

- Up to 8 builders at once, raised only if disk, memory and the CI queue hold up. GitHub runs at most 5 macOS CI jobs at once on this repo.
- Builders that edit the same files don't run side by side. The orchestrator checks this before starting one.
- **One live-app lane, held by the Live checks session.** Only it drives the live app: fn, the mic, paste, Accessibility, the Lexicon Dev window. Everyone else stays headless (the real pipeline on a WAV, no mic, keys or network).
- Worktrees share SwiftPM's one dependency cache. Each has its own `.build/`. Once a ticket merges, its worktree and build folder are deleted.

## Live checks

The lane is a lock: `scripts/live-lane.sh take "Live checks"` writes `~/Library/Application Support/Lexicon Dev/live-lane.lock` with the holder's name and its session's PID. `scripts/dev-run.sh` and `scripts/harness.sh` refuse to run for any other session, naming the holder. A lock whose process has ended is stale and cleared on the next read. `status` shows the holder; `release` gives the lane back.

A builder whose ticket needs the live app sends the Live checks session one request by message once its branch is pushed:

- the issue, branch, PR (or "no PR yet") and head sha;
- a numbered checklist, one observable behavior per item, each with its pass bar ("3. Paste into TextEdit's empty document: the text lands at the cursor and the clipboard is restored");
- anything Jake must do by hand, so the Live checks session can batch it with other asks.

The Live checks session takes requests in arrival order (the orchestrator's critical path first). For each, it checks out that sha detached in its own worktree, launches it with `scripts/dev-run.sh -- --test-hooks`, runs each item with the harness, and posts one comment on the builder's issue headed `Live checks: <branch> @ <sha>`: pass or fail per item, the numbers, and screenshot paths. A failure comes with the evidence, not a fix; the builder fixes it and sends a new request. The PR cites that comment as its live-app evidence.

## The loop

1. **Issue.** Every real change starts as a GitHub issue, labeled and commented as [triage-labels.md](triage-labels.md) says. The first line of every comment states the status.
2. **Grill** (Jake plus an agent), in rounds of numbered questions, each with a recommendation. New terms go into `GLOSSARY.md` as they settle; hard-to-reverse decisions become ADRs in `docs/adr/`. The decisions are posted **on the issue**: if it's not on the issue, it didn't happen.
   - The orchestrator grills work that spans areas, decides priorities, or changes the architecture.
   - A builder grills a self-contained issue it will build next, posts the decisions on the issue and **waits for Jake's OK** before building.
3. **Spec and tickets** (orchestrator): small vertical slices, each `ready-for-agent`, each naming its test seam, modules and blockers. The spec issue itself gets no triage label.
4. **Builder prompt** (orchestrator): "Build issue #N with the implement-ticket skill.", plus the exact scope, the files other builders own right now, and which acceptance criteria need the Live checks session. Keep linear tickets in one builder; use separate builders for independent work.
5. **Build** (builder): the implement-ticket skill, from claim to a PR ready for review, then the next approved unblocked ticket. It stops for a real blocker, an unresolved decision or the end of its sequence.
6. **Review and merge** (Reviewer): every PR says `Refs #N` and never a closing keyword. The Reviewer merges as below.
7. **Install** (Reviewer, only after Jake says "install").
8. **Closing.** Plumbing tickets (build, docs, workflow, stores, scorers, anything Jake can't feel in the app) are closed as soon as they merge; the orchestrator closes them. Tickets Jake can feel (fn, paste, the pill, setup, Cleanup quality, Re-speak) stay open until **Jake closes them** after using the change in his daily copy.

## Merging

The Reviewer merges one PR at a time, only on its own merge verdict, with plain `gh`:

```bash
gh pr view <pr> --json headRefOid,baseRefName,state,isDraft,mergeable
gh pr checks <pr> --watch --fail-fast
gh api repos/jparker2006/lexicon/compare/main...<head sha> --jq .behind_by
gh pr merge <pr> --squash --match-head-commit <head sha>
```

- The head sha is the one it reviewed. A newer push means a new review.
- `gh pr checks` must show the `CI` check passed on that head. Right after a push, CI may show no run yet: wait, never call it a failure. A newer push cancels a waiting run; judge a commit by its own runs.
- `behind_by` must be 0. When the branch is behind `main`, the Reviewer merges `main` into it (in a temporary worktree, `git merge origin/main`, never a rebase) and pushes. That new head needs only a look at what the merge changed (its conflict resolutions), then green CI, before the Reviewer merges with the new sha.
- `--match-head-commit` makes GitHub refuse the merge if anyone pushed after the review. On any refusal or unknown result, it reads the PR again; it never retries blindly.
- After each merge, the next PR is behind `main` until it is brought up to date. The Reviewer deletes the merged branch (`git push origin --delete <branch>`), and the builder's worktree and `.build/` once that builder is done.

## Installing

Jake says "install" and the Reviewer runs the install command for one commit on `main` whose CI passed; one "install" covers one install. The command (it lands with the bundle scripts ticket) builds a release, waits if a Dictation is in progress, swaps it into `~/Applications/Lexicon.app` and relaunches it, keeping its permissions. Afterwards it comments `Installed: <sha>` on each issue that commit carries. Nobody else installs over the daily copy, and nobody installs without his word.

## Dev builds

The Live checks session runs **Lexicon Dev**: its own bundle ID and data folder (`~/Library/Application Support/Lexicon Dev/`), signed with the "Lexicon Dev" certificate so its permissions persist across rebuilds, installed at `~/Applications/Lexicon Dev.app` and launched with `open`. It never touches the daily copy or its permissions.
