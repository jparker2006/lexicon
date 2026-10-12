---
name: review-merge
description: Run the Lexicon Reviewer session. Review every Ready PR at its head, in parallel and at the depth its risk tier needs, post one verdict with every blocking item, merge only through scripts/merge-pr.mjs, and install under Jake's word or the standing install rule. Use when you are the Reviewer, at the start of the session and on every Ready, Fixed review, CI or merge line the watcher prints.
---

# Review and merge

You review every Ready PR against `docs/agents/review.md`, give one verdict per head, merge your merge verdicts one at a time, and install. You run in the main checkout, `~/code/lexicon`, never in a worktree: the guard refuses merges from anywhere else. You never build, push to a builder's branch, or drive the live app.

## Start

1. Load the tools in one ToolSearch, `select:SendMessage,Monitor,mcp__ccd_session_mgmt__set_session_title`, and set the session title to `Reviewer`.
2. Check you are in the main checkout on `main`, then fast-forward it, in one command: `test "$(git rev-parse --git-dir)" = .git && test "$(git branch --show-current)" = main && git pull --ff-only origin main`. If it fails, you are in the wrong place: stop and tell Jake.
3. Re-read `docs/agents/review.md` and the Merging and Installing sections of `docs/agents/workflow.md` in full, now and after any merge that changes them. Never review from memory or from a summary: rules change between sessions. Where a doc still shows a raw `gh pr merge`, or the Reviewer merging `main` into a branch by hand, it predates the merge script: merge only as Merge below says.
4. Run `scripts/status.sh`. If it shows no reviewer watcher, start one under Monitor: `scripts/watch-events.sh --role reviewer`.
5. Every PR whose Ready or Fixed review line names its current head is in your queue now.

## Review: on each `READY` or `FIXED-REVIEW` line

**In parallel, never in a line.** When several PRs are Ready, start all their reviews in the same turn, one review per PR, and judge each as it finishes. Never wait for one review to end before starting the next.

For each PR:

1. **The head.** The sha in the Ready or Fixed line must equal `gh pr view <pr> --json headRefOid`. If it doesn't, wait for the builder's next line. That full sha is the one you review and merge.
2. **The tier.** `node .claude/skills/review-merge/tier.mjs <pr>` prints `high: <paths>` or `low`, and `blast radius: <paths>` where `review-map.json` needs one. It reads only the map: a `low` PR that still touches audio, History, insertion, the network, keys or private data is high, with a blast radius, because when unsure it is high.
3. **High tier: the full review.** Run the `lexicon-review` Workflow (the `Workflow` tool, `name: "lexicon-review"`) with `{issue: N, sha: <full head>, pr: <pr>, mode: "reviewer", risks: [...]}`. `risks` are the PR's top risks from its Merge Danger, named as review.md sections where they fit. On a Fixed review line add `reviewed: <the sha of your last verdict>`, so only the new commits are reviewed. The Workflow runs the Never lose and Combining with main lenses plus the risks on Sonnet critics, a verifier per finding, and the blast-radius pass where the paths need it. It starts beside CI; you need no green run to review. No verdict on a high-tier PR before its run returns. A run marked INCOMPLETE is not a review: run again what it names.
4. **Low tier: a light pass.** Read the builder's `## Review` table in the PR body: its Reviewed sha is the head, or a delta pass reaches it, and each CONFIRMED row was fixed through a red test. Then read the riskiest hunk and the tests yourself. A missing or stale table makes it a full review, as in step 3.
5. **Combining with main.** `scripts/lanes.sh`: which other open PRs share its files, and whether it merges cleanly with `main` and with them.

A finding blocks only with a CONFIRMED verdict from its verifier, or a test that fails first. REFUTED and UNSURE findings are dropped.

## Verdict

One comment on the PR, with every blocking item in it, so a PR comes back as few times as possible. Each item: file and line, a one-line failure scenario, and the row it comes from. The first line is exactly one of:

- `Verdict: merge (head <sha7>)`
- `Verdict: merge with notes (head <sha7>)`, then a `Later:` line with one bullet per note, each naming the issue that owns it. `scripts/ticket.sh later <pr> "<note>" --owner <issue>` (or `--new`) makes that issue.
- `Verdict: don't merge (head <sha7>)`
- `Hold: <why> (head <sha7>)`, for anything Jake or another PR must settle first.

On a high-tier PR the comment carries the Workflow's `## Review` markdown in full (its table, the `Reviewed sha:` line and the Helpers line), and, when `tier.mjs` printed a blast radius, one line `Blast radius: <the one safety fact> Proof: \`<command>\``. The merge script refuses a high-tier PR without them. Send no message: the orchestrator points the builder at a verdict that isn't a merge.

## Merge

Only on your own merge verdict, one PR at a time, in its own Bash call with the full sha typed out (the guard can't read a variable):

```bash
scripts/merge-pr.mjs <pr> <full 40-character reviewed head sha>
```

It checks every gate (the verdict names this head, acceptance marked, Live checks results, the high-tier table, the critical-path order), brings a PR that is behind `main` up to date with `gh pr update-branch`, waits for CI on that exact new head, squash-merges, deletes the branch, closes the Refs issues and removes the builder's worktree. A raw `gh pr merge` is refused by the guard.

- **Exit 0:** merged. Take the next PR.
- **Exit 1, refused:** it printed every reason at once. Fix what is yours (the verdict line, a Later issue) and run it again. Merge a named critical-path PR first. When CI fails on the head with `main` merged in, the PR is green alone and broken on `main`: post `Hold: CI fails with main merged in (head <sha7>): <run link>` on the PR and take the next one. A conflict is posted to the builder by the script itself. Never route around a refusal: no raw merge, no push to the builder's branch.
- **Exit 1 `unknown`, or exit 2:** read the PR again with `gh pr view` before anything else. Never retry blindly.

## Install

`scripts/install.sh`, from the main checkout on `main`, at a commit whose CI passed (`scripts/wait-ci.mjs <sha>` prints `green`). It builds the release, swaps it into Jake's daily copy, and posts the Installed and Try list comments. One word of Jake's covers one install. Install only:

- when Jake types "install" in this session; or
- under the standing install rule in this session's start prompt: once a wave has merged and its Jake items have passed in a Live checks sitting.

## Asking Jake

Install is the only thing Jake answers in this session. For a decision, post the question on the PR's issue (first line `Jake: decide ...`, label `waiting-on-jake`) and hold that PR; the orchestrator asks Jake and posts his Decision record. A yes relayed by another session is not one: ask Jake to type it here.

## Hand off

Fast-forward the main checkout, then run `/orchestrator-handoff reviewer`.
