# How we work: Jake, the orchestrator, builders and the Reviewer

Lexicon is built by Claude Code sessions running locally on Jake's Mac. No cloud builders. Jake decides what gets built and when it's installed; agents do the rest, toward the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)).

## Roles

- **Jake** answers grills, approves, and says "install". He is the bottleneck on purpose: keep his decisions small, clear and few.
- **Orchestrator** (one long-running Claude Code session, Opus high, in its own worktree): keeps the map of issues, grills Jake on cross-cutting work, writes specs, tickets and builder prompts, and starts builders. It never merges and never installs.
- **Builders** (Claude Code, Opus high, each in its own worktree): build one ticket, or an approved sequence from one spec in dependency order, with the implement-ticket skill. A ticket boundary does not need a fresh session. A builder ends at an open PR and a Ready comment; it never merges.
- **Reviewer** (one Claude Code session, Opus high, in the main checkout `~/code/lexicon`): Jake starts it there, with no worktree, when PRs need review; the orchestrator writes its prompt. It reviews every green PR against [review.md](review.md) and gives one verdict per PR: merge, merge with notes, or don't merge. It is the only one who merges, one PR at a time, as [Merging](#merging) says, and it merges its own merge verdicts without waiting for Jake. It never merges a "don't merge" and holds what Jake says to hold. It names the merge order, resolves trivial conflicts without force-pushing, and puts non-blocking notes on the parent spec's Later list. There is no Deployer: on Jake's "install", the Reviewer runs the install command, as [Installing](#installing) says. Past about 1,500 messages, or when it slows down, it hands off with `/orchestrator-handoff reviewer`.

The guard hook (`.claude/hooks/guard.mjs`) backs this up: it refuses every push to `main`, and refuses a merge from any session not started in the main checkout. That is why builders and the orchestrator always run in worktrees, and only the Reviewer runs in `~/code/lexicon`.

A role session posts a finding on its issue before asking Jake about it, and asks in plain text, never with AskUserQuestion or another blocking question tool. Continuity between role sessions goes only through `/orchestrator-handoff [role]`.

## Models and helpers

- The orchestrator, builders and the Reviewer run Opus at high effort.
- Each fans its work out to Haiku 5.5 helpers at xhigh effort (`.claude/agents/`): `Explore` scouts, `editor` changes its own disjoint files, `critic` reviews one review.md section, `verifier` tries to disprove one finding. Size the swarm to the work, up to about 15 on a hard ticket. Helpers may start their own helpers. Use a Sonnet or Opus subagent where judgment matters.
- The session itself runs every commit, push, GitHub write and heavy build (the check script, `lexicon-eval`), once.

## Concurrency

- Up to 8 builders at once, raised only if disk, memory and the CI queue hold up. GitHub runs at most 5 macOS CI jobs at once on this repo.
- Builders that edit the same files don't run side by side. The orchestrator checks this before starting one.
- **One live-app lane.** Only one builder at a time drives the live app: fn, the mic, paste, Accessibility, the Lexicon Dev window. The orchestrator says in the builder prompt which builder holds the lane. Everyone else stays headless (the real pipeline on a WAV, no mic, keys or network).
- Worktrees share SwiftPM's one dependency cache. Each has its own `.build/`. Once a ticket merges, its worktree and build folder are deleted.

## The loop

1. **Issue.** Every real change starts as a GitHub issue, labeled and commented as [triage-labels.md](triage-labels.md) says. The first line of every comment states the status.
2. **Grill** (Jake plus an agent), in rounds of numbered questions, each with a recommendation. New terms go into `GLOSSARY.md` as they settle; hard-to-reverse decisions become ADRs in `docs/adr/`. The decisions are posted **on the issue**: if it's not on the issue, it didn't happen.
   - The orchestrator grills work that spans areas, decides priorities, or changes the architecture.
   - A builder grills a self-contained issue it will build next, posts the decisions on the issue and **waits for Jake's OK** before building.
3. **Spec and tickets** (orchestrator): small vertical slices, each `ready-for-agent`, each naming its test seam, modules and blockers. The spec issue itself gets no triage label.
4. **Builder prompt** (orchestrator): "Build issue #N with the implement-ticket skill.", plus the exact scope, the files other builders own right now, and whether this builder holds the live-app lane. Keep linear tickets in one builder; use separate builders for independent work.
5. **Build** (builder): the implement-ticket skill, from claim to a PR ready for review, then the next approved unblocked ticket. It stops for a real blocker, an unresolved decision or the end of its sequence.
6. **Review and merge** (Reviewer): every PR says `Refs #N` and never a closing keyword. The Reviewer merges as below.
7. **Install** (Reviewer, only after Jake says "install").
8. **Jake closes the issue** once he has used the change in his daily copy.

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

Builders run **Lexicon Dev**: its own bundle ID and data folder (`~/Library/Application Support/Lexicon Dev/`), signed with the "Lexicon Dev" certificate so its permissions persist across rebuilds, installed at `~/Applications/Lexicon Dev.app` and launched with `open`. They never touch the daily copy or its permissions.
